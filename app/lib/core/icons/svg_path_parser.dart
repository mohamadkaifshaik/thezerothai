import 'dart:math' as math;
import 'dart:ui';

/// Parses SVG path data (the `d` attribute) into a Flutter [Path].
///
/// Supports M/m, L/l, H/h, V/v, C/c, S/s, Q/q, T/t, A/a and Z/z, implicit
/// repeated commands (extra pairs after `M` are `L`), numbers without
/// separators (`.5.5`, `1-2`) and the packed arc flags of minified data
/// (`a1 1 0 01 2 3`). Arcs follow the SVG endpoint-to-centre rules (radii
/// scaled up when too small, zero radii become lines) and are emitted as
/// cubic Beziers of at most a quarter turn each.
///
/// Returns null for malformed data: an unknown command, missing or extra
/// numbers, a non-finite number, or data that does not start with a move.
/// Never throws.
Path? tryParseSvgPath(String data) {
  try {
    return _Parser(data).parse();
  } on FormatException {
    return null;
  }
}

/// [tryParseSvgPath] that returns an empty path for malformed data, so a bad
/// constant draws nothing instead of failing a frame.
Path parseSvgPath(String data) => tryParseSvgPath(data) ?? Path();

class _Parser {
  _Parser(this._s);

  final String _s;
  int _i = 0;

  double _x = 0, _y = 0; // current point
  double _sx = 0, _sy = 0; // subpath start
  double _cx = 0, _cy = 0; // last cubic control (reflected by S)
  double _qx = 0, _qy = 0; // last quad control (reflected by T)
  bool _lastCubic = false, _lastQuad = false;

  Path parse() {
    final path = Path();
    _skipSpace();
    if (_i >= _s.length) return path; // empty data is an empty path
    var command = '';
    var first = true;
    while (true) {
      _skipSpace();
      if (_i >= _s.length) break;
      final c = _s[_i];
      if (_isCommand(c)) {
        command = c;
        _i++;
      } else if (command.isEmpty) {
        throw const FormatException('path data must start with a command');
      } else if (command == 'z' || command == 'Z') {
        throw const FormatException('numbers after a close');
      } else if (command == 'M') {
        command = 'L'; // implicit repeat
      } else if (command == 'm') {
        command = 'l';
      }
      if (first && command != 'M' && command != 'm') {
        throw const FormatException('path data must start with a move');
      }
      first = false;
      _run(path, command);
    }
    return path;
  }

  static bool _isCommand(String c) => 'MmLlHhVvCcSsQqTtAaZz'.contains(c);

  void _run(Path p, String cmd) {
    final rel = cmd == cmd.toLowerCase();
    final dx = rel ? _x : 0.0;
    final dy = rel ? _y : 0.0;
    var cubic = false, quad = false;
    switch (cmd.toUpperCase()) {
      case 'M':
        final x = dx + _num(), y = dy + _num();
        p.moveTo(x, y);
        _x = _sx = x;
        _y = _sy = y;
      case 'L':
        final x = dx + _num(), y = dy + _num();
        p.lineTo(x, y);
        _x = x;
        _y = y;
      case 'H':
        final x = dx + _num();
        p.lineTo(x, _y);
        _x = x;
      case 'V':
        final y = dy + _num();
        p.lineTo(_x, y);
        _y = y;
      case 'C':
        final x1 = dx + _num(), y1 = dy + _num();
        final x2 = dx + _num(), y2 = dy + _num();
        final x = dx + _num(), y = dy + _num();
        p.cubicTo(x1, y1, x2, y2, x, y);
        _cx = x2;
        _cy = y2;
        _x = x;
        _y = y;
        cubic = true;
      case 'S':
        final x1 = _lastCubic ? 2 * _x - _cx : _x;
        final y1 = _lastCubic ? 2 * _y - _cy : _y;
        final x2 = dx + _num(), y2 = dy + _num();
        final x = dx + _num(), y = dy + _num();
        p.cubicTo(x1, y1, x2, y2, x, y);
        _cx = x2;
        _cy = y2;
        _x = x;
        _y = y;
        cubic = true;
      case 'Q':
        final x1 = dx + _num(), y1 = dy + _num();
        final x = dx + _num(), y = dy + _num();
        p.quadraticBezierTo(x1, y1, x, y);
        _qx = x1;
        _qy = y1;
        _x = x;
        _y = y;
        quad = true;
      case 'T':
        final x1 = _lastQuad ? 2 * _x - _qx : _x;
        final y1 = _lastQuad ? 2 * _y - _qy : _y;
        final x = dx + _num(), y = dy + _num();
        p.quadraticBezierTo(x1, y1, x, y);
        _qx = x1;
        _qy = y1;
        _x = x;
        _y = y;
        quad = true;
      case 'A':
        final rx = _num(), ry = _num(), rot = _num();
        final large = _flag(), sweep = _flag();
        final x = dx + _num(), y = dy + _num();
        _arc(p, _x, _y, rx, ry, rot, large, sweep, x, y);
        _x = x;
        _y = y;
      case 'Z':
        p.close();
        _x = _sx;
        _y = _sy;
    }
    _lastCubic = cubic;
    _lastQuad = quad;
  }

  void _skipSpace() {
    while (_i < _s.length) {
      final u = _s.codeUnitAt(_i);
      if (u == 0x20 || u == 0x2C || (u >= 0x09 && u <= 0x0D)) {
        _i++;
      } else {
        break;
      }
    }
  }

  double _num() {
    _skipSpace();
    final start = _i;
    if (_i < _s.length && (_s[_i] == '-' || _s[_i] == '+')) _i++;
    var digits = 0;
    while (_i < _s.length && _isDigit(_s.codeUnitAt(_i))) {
      _i++;
      digits++;
    }
    if (_i < _s.length && _s[_i] == '.') {
      _i++;
      while (_i < _s.length && _isDigit(_s.codeUnitAt(_i))) {
        _i++;
        digits++;
      }
    }
    if (digits == 0) throw const FormatException('expected a number');
    if (_i < _s.length && (_s[_i] == 'e' || _s[_i] == 'E')) {
      var j = _i + 1;
      if (j < _s.length && (_s[j] == '-' || _s[j] == '+')) j++;
      final expStart = j;
      while (j < _s.length && _isDigit(_s.codeUnitAt(j))) {
        j++;
      }
      if (j > expStart) _i = j;
    }
    final v = double.tryParse(_s.substring(start, _i));
    if (v == null || !v.isFinite) {
      throw const FormatException('bad number');
    }
    return v;
  }

  bool _flag() {
    _skipSpace();
    if (_i >= _s.length) throw const FormatException('expected an arc flag');
    final c = _s[_i];
    if (c != '0' && c != '1') throw const FormatException('bad arc flag');
    _i++;
    return c == '1';
  }

  static bool _isDigit(int u) => u >= 0x30 && u <= 0x39;
}

/// SVG arc (implementation notes F.6) as cubic segments.
void _arc(
  Path p,
  double x1,
  double y1,
  double rxIn,
  double ryIn,
  double rotDeg,
  bool large,
  bool sweep,
  double x2,
  double y2,
) {
  var rx = rxIn.abs(), ry = ryIn.abs();
  if (x1 == x2 && y1 == y2) return; // omitted per spec
  if (rx == 0 || ry == 0) {
    p.lineTo(x2, y2);
    return;
  }
  final phi = rotDeg * math.pi / 180;
  final cosP = math.cos(phi), sinP = math.sin(phi);
  final dx2 = (x1 - x2) / 2, dy2 = (y1 - y2) / 2;
  final x1p = cosP * dx2 + sinP * dy2;
  final y1p = -sinP * dx2 + cosP * dy2;
  final lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
  if (lambda > 1) {
    final s = math.sqrt(lambda);
    rx *= s;
    ry *= s;
  }
  final top = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
  final bottom = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
  var coef = bottom == 0 ? 0.0 : math.sqrt(math.max(0, top / bottom));
  if (large == sweep) coef = -coef;
  final cxp = coef * (rx * y1p / ry);
  final cyp = coef * -(ry * x1p / rx);
  final cx = cosP * cxp - sinP * cyp + (x1 + x2) / 2;
  final cy = sinP * cxp + cosP * cyp + (y1 + y2) / 2;

  double angle(double ux, double uy, double vx, double vy) {
    final a = math.atan2(uy, ux);
    final b = math.atan2(vy, vx);
    return b - a;
  }

  final theta1 = math.atan2((y1p - cyp) / ry, (x1p - cxp) / rx);
  var delta = angle(
    (x1p - cxp) / rx,
    (y1p - cyp) / ry,
    (-x1p - cxp) / rx,
    (-y1p - cyp) / ry,
  );
  if (!sweep && delta > 0) delta -= 2 * math.pi;
  if (sweep && delta < 0) delta += 2 * math.pi;

  final segments = (delta.abs() / (math.pi / 2) - 1e-9).ceil().clamp(1, 4);
  final step = delta / segments;
  final t = 4 / 3 * math.tan(step / 4);
  var a1 = theta1;
  for (var k = 0; k < segments; k++) {
    final a2 = a1 + step;
    final c1 = math.cos(a1), s1 = math.sin(a1);
    final c2 = math.cos(a2), s2 = math.sin(a2);
    // Control points on the unit circle, then scaled, rotated, moved.
    Offset map(double ux, double uy) => Offset(
      cosP * rx * ux - sinP * ry * uy + cx,
      sinP * rx * ux + cosP * ry * uy + cy,
    );
    final p1 = map(c1 - t * s1, s1 + t * c1);
    final p2 = map(c2 + t * s2, s2 - t * c2);
    final end = k == segments - 1 ? Offset(x2, y2) : map(c2, s2);
    p.cubicTo(p1.dx, p1.dy, p2.dx, p2.dy, end.dx, end.dy);
    a1 = a2;
  }
}
