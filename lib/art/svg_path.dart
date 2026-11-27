import 'dart:ui';

/// An SVG path's `d` as a [Path]: every command the specification has, absolute and relative, with an arc's flags
/// read as the single characters they are (lucide sets them against the next number with no space).
///
/// The web app's drawings are SVG paths (art/Icons.tsx, art/ghostMark.ts, art/gears.ts and the kit's lucide icons),
/// and they are carried here as the strings they are written as there, so a drawing changed on the page is changed
/// here by copying its line.
Path parseSvgPath(String d) {
  final path = Path();
  var at = 0;
  // Past spaces, commas and line ends: whatever stands between two numbers.
  void skip() {
    while (at < d.length) {
      final c = d.codeUnitAt(at);
      if (c == 0x20 || c == 0x2c || c == 0x0a || c == 0x09 || c == 0x0d) {
        at++;
      } else {
        break;
      }
    }
  }

  // The next number: a sign, digits with at most one point, and an exponent where digits follow its e. A second
  // point or a sign starts the next number, as paths are written with nothing between ("1.5.5", "0-3").
  double number() {
    skip();
    final start = at;
    if (at < d.length && (d[at] == '-' || d[at] == '+')) at++;
    var dot = false;
    while (at < d.length) {
      final c = d.codeUnitAt(at);
      if (c >= 0x30 && c <= 0x39) {
        at++;
      } else if (c == 0x2e && !dot) {
        dot = true;
        at++;
      } else {
        break;
      }
    }
    if (at < d.length && (d[at] == 'e' || d[at] == 'E')) {
      final mark = at;
      at++;
      if (at < d.length && (d[at] == '-' || d[at] == '+')) at++;
      final digits = at;
      while (at < d.length && d.codeUnitAt(at) >= 0x30 && d.codeUnitAt(at) <= 0x39) {
        at++;
      }
      if (at == digits) at = mark;
    }
    if (at == start) throw FormatException('no number at $start in "$d"');
    return double.parse(d.substring(start, at));
  }

  bool flag() {
    skip();
    final set = at < d.length && d[at] == '1';
    at++;
    return set;
  }

  // A letter is a command, but for e and E, which belong to a number's exponent.
  bool isCommand(int c) => (c >= 0x41 && c <= 0x5a && c != 0x45) || (c >= 0x61 && c <= 0x7a && c != 0x65);

  var x = 0.0, y = 0.0, startX = 0.0, startY = 0.0;
  // The last control point, for the smooth commands that mirror it.
  double? cubicX, cubicY, quadX, quadY;
  var command = '';
  while (true) {
    skip();
    if (at >= d.length) break;
    if (isCommand(d.codeUnitAt(at))) {
      command = d[at];
      at++;
    } else if (command.isEmpty) {
      throw FormatException('no command in "$d"');
    }
    final rel = command == command.toLowerCase();
    double px(double v) => rel ? x + v : v;
    double py(double v) => rel ? y + v : v;
    final kind = command.toUpperCase();
    double? nextCubicX, nextCubicY, nextQuadX, nextQuadY;
    switch (kind) {
      case 'M':
        x = px(number());
        y = py(number());
        startX = x;
        startY = y;
        path.moveTo(x, y);
        // Further pairs after a move are lines.
        command = rel ? 'l' : 'L';
      case 'L':
        final nx = px(number()), ny = py(number());
        x = nx;
        y = ny;
        path.lineTo(x, y);
      case 'H':
        x = rel ? x + number() : number();
        path.lineTo(x, y);
      case 'V':
        y = rel ? y + number() : number();
        path.lineTo(x, y);
      case 'C':
        final x1 = px(number()), y1 = py(number()), x2 = px(number()), y2 = py(number()), nx = px(number()), ny = py(number());
        path.cubicTo(x1, y1, x2, y2, nx, ny);
        nextCubicX = x2;
        nextCubicY = y2;
        x = nx;
        y = ny;
      case 'S':
        final x1 = cubicX == null ? x : 2 * x - cubicX, y1 = cubicY == null ? y : 2 * y - cubicY;
        final x2 = px(number()), y2 = py(number()), nx = px(number()), ny = py(number());
        path.cubicTo(x1, y1, x2, y2, nx, ny);
        nextCubicX = x2;
        nextCubicY = y2;
        x = nx;
        y = ny;
      case 'Q':
        final x1 = px(number()), y1 = py(number()), nx = px(number()), ny = py(number());
        path.quadraticBezierTo(x1, y1, nx, ny);
        nextQuadX = x1;
        nextQuadY = y1;
        x = nx;
        y = ny;
      case 'T':
        final x1 = quadX == null ? x : 2 * x - quadX, y1 = quadY == null ? y : 2 * y - quadY;
        final nx = px(number()), ny = py(number());
        path.quadraticBezierTo(x1, y1, nx, ny);
        nextQuadX = x1;
        nextQuadY = y1;
        x = nx;
        y = ny;
      case 'A':
        final rx = number(), ry = number(), turn = number();
        final large = flag(), sweep = flag();
        final nx = px(number()), ny = py(number());
        if (rx == 0 || ry == 0) {
          path.lineTo(nx, ny);
        } else {
          path.arcToPoint(Offset(nx, ny), radius: Radius.elliptical(rx.abs(), ry.abs()), rotation: turn, largeArc: large, clockwise: sweep);
        }
        x = nx;
        y = ny;
      case 'Z':
        path.close();
        x = startX;
        y = startY;
      default:
        throw FormatException('unknown command $command in "$d"');
    }
    cubicX = nextCubicX;
    cubicY = nextCubicY;
    quadX = nextQuadX;
    quadY = nextQuadY;
  }
  return path;
}

/// The paths parsed so far, by the string each was written as: one kind filled the usual way, one even-odd.
final Map<String, Path> _paths = {}, _evenOdd = {};

/// No more paths than this are kept of either kind. The icons' own are a few hundred strings, there for good; a
/// caller that writes a path out afresh for every place it draws (the canvas's map does, for the box it shows)
/// would otherwise leave one here for every place it ever drew.
const int _kept = 4096;

/// [parseSvgPath], kept by its string: a drawing's path is made once however often it is drawn. With [evenOdd],
/// the same path filled even-odd, kept too (a body with a hole in it, drawn at every paint, was a copy at every
/// paint). The path is everyone's who asks for that string: it is drawn, and never changed.
Path svgPath(String d, {bool evenOdd = false}) {
  final store = evenOdd ? _evenOdd : _paths;
  final had = store[d];
  if (had != null) return had;
  // Past the bound, the quarter kept longest goes: a string still drawn is parsed once more, and that is all.
  if (store.length >= _kept) {
    for (final old in store.keys.take(_kept ~/ 4).toList()) {
      store.remove(old);
    }
  }
  return store[d] = evenOdd ? (Path.from(svgPath(d))..fillType = PathFillType.evenOdd) : parseSvgPath(d);
}

/// How many paths are kept, plain and even-odd: for a test.
int get debugSvgPathsKept => _paths.length + _evenOdd.length;
