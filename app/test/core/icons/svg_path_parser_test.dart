import 'dart:ui';

import 'package:dzeroth/core/icons/svg_path_parser.dart';
import 'package:flutter_test/flutter_test.dart';

double _length(Path p) =>
    p.computeMetrics().fold(0.0, (sum, m) => sum + m.length);

/// Largest y on the drawn curve (getBounds also counts control points).
double _tightBottom(Path p) {
  var bottom = double.negativeInfinity;
  for (final m in p.computeMetrics()) {
    for (var i = 0; i <= 200; i++) {
      final y = m.getTangentForOffset(m.length * i / 200)!.position.dy;
      if (y > bottom) bottom = y;
    }
  }
  return bottom;
}

/// The point where the last contour ends.
Offset _end(Path p) {
  final m = p.computeMetrics().last;
  return m.getTangentForOffset(m.length)!.position;
}

Path _p(String d) {
  final p = tryParseSvgPath(d);
  expect(p, isNotNull, reason: d);
  return p!;
}

void main() {
  group('lines', () {
    test('M and L', () {
      final p = _p('M0 0L10 0L10 10');
      expect(p.getBounds(), const Rect.fromLTRB(0, 0, 10, 10));
      expect(_length(p), closeTo(20, 1e-6));
    });

    test('relative m and l start from the current point', () {
      final p = _p('m1 1 l2 3');
      expect(p.getBounds(), const Rect.fromLTRB(1, 1, 3, 4));
      expect(_end(p), const Offset(3, 4));
    });

    test('H, V, h and v', () {
      final p = _p('M0 0H10V5h-4v-2');
      expect(_end(p), const Offset(6, 3));
      expect(_length(p), closeTo(10 + 5 + 4 + 2, 1e-6));
    });

    test('extra pairs after M are lines, after m relative lines', () {
      expect(_length(_p('M0 0 10 0 10 10')), closeTo(20, 1e-6));
      final rel = _p('m0 0 10 0 0 10');
      expect(_end(rel), const Offset(10, 10));
    });

    test('implicit repeats of every command', () {
      expect(_end(_p('M0 0 l1 1 2 2')), const Offset(3, 3));
      expect(_end(_p('M0 0 h1 2 3')), const Offset(6, 0));
      expect(_end(_p('M0 0 v1 2 3')), const Offset(0, 6));
    });

    test('Z closes to the subpath start, and a following relative move', () {
      final p = _p('M0 0h10v10z');
      expect(_length(p), closeTo(20 + 14.142135, 1e-4));
      final two = _p('M0 0h10v10zm1 1h2');
      // After z the current point is the start (0,0); m1 1 moves to (1,1).
      expect(_end(two), const Offset(3, 1));
    });

    test('numbers without separators and with exponents', () {
      final p = _p('M.5.5L1.5-.5');
      expect(p.getBounds(), const Rect.fromLTRB(0.5, -0.5, 1.5, 0.5));
      expect(_end(_p('M0 0L1e1 2E0')), const Offset(10, 2));
      expect(_end(_p('M0,0,L5,5')), const Offset(5, 5));
      expect(_end(_p('M0 0L+3 +4')), const Offset(3, 4));
    });

    test('empty data is an empty path, not an error', () {
      expect(_p('').getBounds(), Rect.zero);
      expect(_p('  ').getBounds(), Rect.zero);
    });
  });

  group('curves', () {
    test('C reaches the endpoint and the curve apex', () {
      final p = _p('M0 0C0 10 10 10 10 0');
      expect(_end(p), const Offset(10, 0));
      // Apex of this cubic is 0.75 * 10 = 7.5.
      expect(_tightBottom(p), closeTo(7.5, 0.01));
    });

    test('relative c', () {
      final abs = _p('M5 5C5 15 15 15 15 5');
      final rel = _p('M5 5c0 10 10 10 10 0');
      expect(rel.getBounds(), abs.getBounds());
    });

    test('S reflects the previous cubic control point', () {
      final s = _p('M0 0C0 5 5 5 5 0S10 -5 10 0');
      final c = _p('M0 0C0 5 5 5 5 0C5 -5 10 -5 10 0');
      expect(_length(s), closeTo(_length(c), 1e-6));
      expect(s.getBounds(), c.getBounds());
    });

    test('S after a non-cubic uses the current point as first control', () {
      final s = _p('M0 0L5 0S10 5 10 0');
      final c = _p('M0 0L5 0C5 0 10 5 10 0');
      expect(_length(s), closeTo(_length(c), 1e-6));
    });

    test('relative s', () {
      final abs = _p('M0 0C0 5 5 5 5 0S10 -5 10 0');
      final rel = _p('M0 0C0 5 5 5 5 0s5 -5 5 0');
      expect(_length(rel), closeTo(_length(abs), 1e-6));
    });

    test('Q and relative q', () {
      final q = _p('M0 0Q5 10 10 0');
      expect(_tightBottom(q), closeTo(5, 0.01)); // apex = half control
      expect(_length(_p('M0 0q5 10 10 0')), closeTo(_length(q), 1e-6));
    });

    test('T reflects the previous quad control point', () {
      final t = _p('M0 0Q5 10 10 0T20 0');
      final q = _p('M0 0Q5 10 10 0Q15 -10 20 0');
      expect(_length(t), closeTo(_length(q), 1e-6));
      expect(t.getBounds(), q.getBounds());
      expect(_length(_p('M0 0q5 10 10 0t10 0')), closeTo(_length(q), 1e-6));
    });

    test('T after a non-quad is a straight line', () {
      expect(_length(_p('M0 0T10 0')), closeTo(10, 1e-6));
    });
  });

  group('arcs', () {
    test('a semicircle, sweep 1 passes above in SVG (y down) space', () {
      final p = _p('M0 0A10 10 0 0 1 20 0');
      // Path metrics approximate curves; 1 % is well inside that.
      expect(_length(p), closeTo(10 * 3.14159265, 0.35));
      expect(p.getBounds().top, closeTo(-10, 1e-6));
      expect(p.getBounds().bottom, closeTo(0, 1e-4));
      expect(_end(p).dx, closeTo(20, 1e-4));
      expect(_end(p).dy, closeTo(0, 1e-4));
    });

    test('sweep 0 goes the other way', () {
      final p = _p('M0 0A10 10 0 0 0 20 0');
      expect(p.getBounds().bottom, closeTo(10, 1e-6));
    });

    test('a quarter circle passes through the 45 degree point', () {
      final p = _p('M10 0A10 10 0 0 1 0 10');
      expect(_length(p), closeTo(10 * 3.14159265 / 2, 0.2));
      final m = p.computeMetrics().single;
      final mid = m.getTangentForOffset(m.length / 2)!.position;
      expect(mid.dx, closeTo(7.0710678, 1e-3));
      expect(mid.dy, closeTo(7.0710678, 1e-3));
    });

    test('large-arc flag picks the long way round', () {
      final small = _p('M0 0A10 10 0 0 1 10 10');
      final large = _p('M0 0A10 10 0 1 1 10 10');
      expect(_length(small), closeTo(10 * 3.14159265 / 2, 0.2));
      expect(_length(large), closeTo(10 * 3.14159265 * 1.5, 0.5));
    });

    test('radii too small are scaled up to the minimum circle', () {
      final p = _p('M0 0A1 1 0 0 1 20 0');
      expect(p.getBounds().top, closeTo(-10, 1e-6));
    });

    test('zero radius is a line, identical endpoints draw nothing', () {
      expect(_length(_p('M0 0A0 5 0 0 1 10 0')), closeTo(10, 1e-6));
      expect(_length(_p('M3 3A5 5 0 0 1 3 3')), 0);
    });

    test('relative a and packed flags', () {
      final p = _p('M0 0a5 5 0 0110 0');
      expect(p.getBounds().top, closeTo(-5, 1e-6));
      expect(_end(p).dx, closeTo(10, 1e-6));
    });

    test('a rotated ellipse arc ends where it was told to', () {
      final p = _p('M0 0A20 5 30 0 1 12 8');
      final e = _end(p);
      expect(e.dx, closeTo(12, 1e-6));
      expect(e.dy, closeTo(8, 1e-6));
    });

    test('a full circle from two arcs stays inside its bounds', () {
      final p = _p('M0 5a5 5 0 1 0 10 0a5 5 0 1 0-10 0z');
      final b = p.getBounds();
      expect(b.left, closeTo(0, 1e-6));
      expect(b.right, closeTo(10, 1e-6));
      expect(b.top, closeTo(0, 1e-6));
      expect(b.bottom, closeTo(10, 1e-6));
    });
  });

  group('malformed data fails safely', () {
    const bad = [
      'L0 0', // no move first
      '0 0 L1 1', // numbers first
      'M0', // missing y
      'M0 0 L1', // missing y
      'M0 0 X 1 1', // unknown command
      'M0 0 L1 1 Z 5 5', // numbers after a close
      'M0 0 A1 1 0 2 0 5 5', // bad flag
      'M0 0 C1 1 2 2 3', // truncated curve
      'M0 0 L1 1 ?', // junk
      'M-- 0',
      'M1e999 0', // not finite
      'M0 0 .', // lone dot
    ];
    for (final d in bad) {
      test('"$d"', () {
        expect(tryParseSvgPath(d), isNull);
        expect(parseSvgPath(d).getBounds(), Rect.zero);
      });
    }
  });
}
