import 'dart:math' as math;

/// Which shapes of an icon wear the wash (art/iconWash.ts; app.css "Icons are outlines, with a wash inside").
///
/// An icon is several shapes, and the wash filled whole doubles up inside it and loses the detail. So the wash goes
/// on the icon's body alone: its largest closed shape - a box, a circle, a path that comes back to where it began -
/// and any other closed shape of some size that sits clear of it. A shape inside the body is detail and stays a
/// stroke. An open path is never washed, since a fill closes it with a straight line from its end to its start. An
/// icon with no closed shape has no body and stays an outline.
///
/// Pure Dart, with nothing of Flutter's in it: tool/lucide.dart runs it to make lib/art/lucide.g.dart, where the
/// page makes iconWash.css from the same rule.
class IconShape {
  const IconShape(this.tag, this.attrs);

  /// The svg element it is (`path`, `rect`, `circle`…), and its attributes as written.
  final String tag;
  final Map<String, String> attrs;
}

/// The box round a shape, in the icon's own units: what shapes are ranked and told apart by.
class IconBounds {
  const IconBounds(this.left, this.top, this.right, this.bottom);
  final double left, top, right, bottom;
  double get area => math.max(0, right - left) * math.max(0, bottom - top);
}

/// The least a body's box covers, of the icon's 24 by 24: a dot is not a body.
const double _leastArea = 24;

/// A second shape is washed too when it is at least this much of the first, and clear of it.
const double _beside = 0.3;

/// How near a path's end is to its start for it to have come back: under a stroke's width.
const double _closed = 0.75;

double _num(String? value, [double fallback = 0]) => value == null ? fallback : double.parse(value);

/// The smallest box that holds every one of [points]; null for none.
IconBounds? _boundsOf(List<(double, double)> points) {
  if (points.isEmpty) return null;
  var left = points.first.$1, right = left, top = points.first.$2, bottom = top;
  for (final (x, y) in points) {
    left = math.min(left, x);
    right = math.max(right, x);
    top = math.min(top, y);
    bottom = math.max(bottom, y);
  }
  return IconBounds(left, top, right, bottom);
}

final RegExp _numberAt = RegExp(r'[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?');
final RegExp _letter = RegExp(r'[a-zA-Z]');

/// A path walked (`walkPath`): the box round every point it names, and whether it is one line that comes back to
/// its start. The box is of the path's end points and control points, which is near enough to rank shapes by; an
/// arc is taken by its ends.
({IconBounds? bounds, bool closed}) walkPath(String d) {
  var at = 0;
  void skip() {
    while (at < d.length && (d[at] == ' ' || d[at] == ',' || d[at] == '\n' || d[at] == '\t' || d[at] == '\r')) {
      at++;
    }
  }

  double number() {
    skip();
    final match = _numberAt.matchAsPrefix(d, at);
    if (match == null) throw FormatException('no number at $at in "$d"');
    at = match.end;
    return double.parse(match.group(0)!);
  }

  /// An arc's flag is one character, and may be set against the next number with no space.
  void flag() {
    skip();
    at++;
  }

  final points = <(double, double)>[];
  var x = 0.0, y = 0.0, startX = 0.0, startY = 0.0;
  var subpaths = 0;
  var allClosed = true, open = false;
  // A stretch of the path ends, by a Z ([zed]) or by the next move: without a Z it counts as closed only where it
  // came back to within a stroke's width of its start.
  void endSubpath(bool zed) {
    if (!open) return;
    if (!zed && math.sqrt((x - startX) * (x - startX) + (y - startY) * (y - startY)) > _closed) allClosed = false;
    open = false;
  }

  var command = '';
  while (true) {
    skip();
    if (at >= d.length) break;
    if (_letter.matchAsPrefix(d, at) != null) {
      command = d[at];
      at++;
    } else if (command.isEmpty) {
      throw FormatException('no command in "$d"');
    }
    final rel = command == command.toLowerCase();
    (double, double) to(double px, double py) => rel ? (x + px, y + py) : (px, py);
    switch (command.toUpperCase()) {
      case 'M':
        endSubpath(false);
        (x, y) = to(number(), number());
        startX = x;
        startY = y;
        subpaths++;
        open = true;
        points.add((x, y));
        // Further pairs after a move are lines.
        command = rel ? 'l' : 'L';
      case 'L' || 'T':
        (x, y) = to(number(), number());
        points.add((x, y));
      case 'H':
        x = rel ? x + number() : number();
        points.add((x, y));
      case 'V':
        y = rel ? y + number() : number();
        points.add((x, y));
      case 'C':
        final a = to(number(), number());
        final b = to(number(), number());
        final end = to(number(), number());
        points.addAll([a, b, end]);
        (x, y) = end;
      case 'S' || 'Q':
        final a = to(number(), number());
        final end = to(number(), number());
        points.addAll([a, end]);
        (x, y) = end;
      case 'A':
        number();
        number();
        number();
        flag();
        flag();
        (x, y) = to(number(), number());
        points.add((x, y));
      case 'Z':
        endSubpath(true);
        x = startX;
        y = startY;
      default:
        throw FormatException('unknown command $command in "$d"');
    }
  }
  endSubpath(false);
  return (bounds: _boundsOf(points), closed: subpaths == 1 && allClosed);
}

/// The box a closed shape covers, or null for one that is open, or is not a shape that can be filled.
IconBounds? _closedBounds(IconShape shape) {
  final a = shape.attrs;
  switch (shape.tag) {
    case 'rect':
      return IconBounds(_num(a['x']), _num(a['y']), _num(a['x']) + _num(a['width']), _num(a['y']) + _num(a['height']));
    case 'circle':
      return IconBounds(_num(a['cx']) - _num(a['r']), _num(a['cy']) - _num(a['r']), _num(a['cx']) + _num(a['r']), _num(a['cy']) + _num(a['r']));
    case 'ellipse':
      return IconBounds(_num(a['cx']) - _num(a['rx']), _num(a['cy']) - _num(a['ry']), _num(a['cx']) + _num(a['rx']), _num(a['cy']) + _num(a['ry']));
    case 'polygon':
      final values = (a['points'] ?? '').trim().split(RegExp(r'[\s,]+')).where((v) => v.isNotEmpty).map(double.parse).toList();
      return _boundsOf([for (var n = 0; n + 1 < values.length; n += 2) (values[n], values[n + 1])]);
    case 'path':
      final walked = walkPath(a['d'] ?? '');
      return walked.closed ? walked.bounds : null;
    default:
      return null;
  }
}

/// Whether two boxes sit clear of each other: side by side or one above the other, overlapping by half a unit at most.
bool _apart(IconBounds a, IconBounds b) => a.right <= b.left + 0.5 || b.right <= a.left + 0.5 || a.bottom <= b.top + 0.5 || b.bottom <= a.top + 0.5;

/// The shapes of an icon that wear the wash (`bodiesOf`), by their place among its shapes (from 0), in that order:
/// its body, and whatever else is closed, of some size, and clear of everything already chosen. None for an icon
/// with no body.
List<int> bodiesOf(List<IconShape> shapes) {
  final closed = <({int index, IconBounds bounds})>[];
  for (var index = 0; index < shapes.length; index++) {
    final bounds = _closedBounds(shapes[index]);
    if (bounds != null && bounds.area >= _leastArea) closed.add((index: index, bounds: bounds));
  }
  closed.sort((a, b) {
    final by = b.bounds.area.compareTo(a.bounds.area);
    return by != 0 ? by : a.index.compareTo(b.index);
  });
  if (closed.isEmpty) return const [];
  final first = closed.first;
  final chosen = [first];
  for (final entry in closed.skip(1)) {
    if (entry.bounds.area >= first.bounds.area * _beside && chosen.every((held) => _apart(held.bounds, entry.bounds))) chosen.add(entry);
  }
  return chosen.map((entry) => entry.index).toList()..sort();
}

/// Bodies the rule above cannot see (`OPEN_BODIES`): a path left open along an edge that another stroke of the
/// icon draws, or that is the shape's own straight side. Chosen by eye on the page, one icon at a time, by the name
/// the kit gives its svg and the shape's place among its shapes.
const Map<String, List<int>> openBodies = {
  'trash': [2, 4],
  'book': [0],
  'flag': [0],
  'lightbulb': [0],
  'hourglass': [2, 3],
  'flask-conical': [0],
  'eraser': [0],
  'download': [1],
  'external-link': [2],
  'log-out': [2],
  'image-plus': [2],
  'gauge': [1],
  'rotate-ccw-clock': [0],
  'archive': [1],
  'archive-x': [1],
  'calendar-plus': [3],
  'calendar-search': [1],
  'database': [1],
  'square-pen': [0],
  'square-check-big': [0],
  'square-arrow-out-up-right': [0],
  'highlighter': [0, 1],
};

/// The icons washed whole by app.css: one closed silhouette each, or dots too small to be a body
/// (`:where(svg.lucide-bookmark, ...)`).
const Set<String> wholeWashed = {'bookmark', 'play', 'puzzle', 'square', 'pause', 'layout-grid', 'ellipsis-vertical'};

/// How much of the icon's own ink the wash is: `color-mix(in srgb, currentColor 33%, transparent)`.
const double iconWash = 0.33;

/// Every shape of [name]'s icon that wears the wash: all of them for an icon washed whole, else its bodies and the
/// open ones named for it.
List<int> washedShapes(String name, List<IconShape> shapes) {
  if (wholeWashed.contains(name)) return [for (var i = 0; i < shapes.length; i++) i];
  return {...bodiesOf(shapes), ...?openBodies[name]}.toList()..sort();
}

/// A Phosphor duotone icon's body: a fifth of the ink, as Phosphor draws it (opacity 0.2).
const double phosphorWash = 0.2;
