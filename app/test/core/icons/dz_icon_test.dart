import 'package:dzeroth/core/icons/dz_icon.dart';
import 'package:dzeroth/core/icons/dz_icon_data.dart';
import 'package:dzeroth/core/icons/dz_icons.dart';
import 'package:dzeroth/core/icons/svg_path_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget _host(Widget child) => Directionality(
  textDirection: TextDirection.ltr,
  child: Center(child: child),
);

void main() {
  group('DzIcons', () {
    for (final MapEntry(:key, :value) in DzIcons.all.entries) {
      test('$key parses, stays on the 24 grid and has something to draw', () {
        for (final shape in value.shapes) {
          if (shape is DzPathShape) {
            expect(tryParseSvgPath(shape.d), isNotNull, reason: shape.d);
          }
        }
        final compiled = value.compiled;
        final bounds = compiled.stroke.getBounds().expandToInclude(
          compiled.dots.getBounds(),
        );
        expect(bounds.isEmpty, isFalse);
        expect(bounds.left, greaterThanOrEqualTo(-0.5));
        expect(bounds.top, greaterThanOrEqualTo(-0.5));
        expect(bounds.right, lessThanOrEqualTo(24.5));
        expect(bounds.bottom, lessThanOrEqualTo(24.5));
      });
    }

    test('the artboards\' five action icons use their exact path data', () {
      String d(DzIconData i) => (i.shapes.single as DzPathShape).d;
      expect(
        d(DzIcons.reply),
        'M21 12a8 8 0 0 1-11.6 7.1L4 20l1-4.6A8 8 0 1 1 21 12z',
      );
      expect(
        d(DzIcons.repost),
        'M17 2l4 4-4 4M3 11V9a3 3 0 0 1 3-3h15M7 22l-4-4 4-4M21 13v2a3 3 0 0 1-3 3H3',
      );
      expect(
        d(DzIcons.like),
        'M12 20s-7-4.4-7-10a4 4 0 0 1 7-2.6A4 4 0 0 1 19 10c0 5.6-7 10-7 10z',
      );
      expect(d(DzIcons.save), 'M6 3h12v18l-6-4-6 4z');
      expect(
        d(DzIcons.share),
        'M12 3v12M7 8l5-5 5 5M5 14v5a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-5',
      );
    });

    test('paths are parsed once per icon', () {
      expect(identical(DzIcons.like.compiled, DzIcons.like.compiled), isTrue);
    });

    test('dots are separate from the strokes', () {
      expect(DzIcons.more.compiled.stroke.getBounds().isEmpty, isTrue);
      expect(DzIcons.more.compiled.dots.getBounds().isEmpty, isFalse);
      expect(DzIcons.plans.compiled.dots.getBounds().isEmpty, isFalse);
    });
  });

  group('DzIcon', () {
    testWidgets('sizes and colours from the IconTheme like Icon', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const IconTheme(
            data: IconThemeData(size: 30, color: Color(0xFF123456)),
            child: DzIcon(DzIcons.like),
          ),
        ),
      );
      expect(tester.getSize(find.byType(DzIcon)), const Size(30, 30));
    });

    testWidgets('explicit size wins', (tester) async {
      await tester.pumpWidget(_host(const DzIcon(DzIcons.like, size: 19)));
      expect(tester.getSize(find.byType(DzIcon)), const Size(19, 19));
    });

    testWidgets('has no semantics without a label', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(const DzIcon(DzIcons.like)));
      expect(find.bySemanticsLabel('Like'), findsNothing);
      handle.dispose();
    });

    testWidgets('a label makes it an image with that label', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(const DzIcon(DzIcons.like, semanticLabel: 'Like')),
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel('Like')),
        matchesSemantics(label: 'Like', isImage: true),
      );
      handle.dispose();
    });

    testWidgets('outline draws a stroke only, fill adds a fill', (
      tester,
    ) async {
      Future<RenderBox> pump(double fill) async {
        await tester.pumpWidget(
          _host(
            DzIcon(
              DzIcons.like,
              size: 24,
              color: const Color(0xFFE11D48),
              fill: fill,
            ),
          ),
        );
        return tester.renderObject<RenderBox>(
          find.descendant(
            of: find.byType(DzIcon),
            matching: find.byType(CustomPaint),
          ),
        );
      }

      var box = await pump(0);
      // Outline: exactly one path, stroked.
      expect(box, paintsExactlyCountTimes(#drawPath, 1));
      expect(
        box,
        paints
          ..path(style: PaintingStyle.stroke, color: const Color(0xFFE11D48)),
      );
      box = await pump(1);
      expect(box, paintsExactlyCountTimes(#drawPath, 2));
      expect(
        box,
        paints
          ..path(style: PaintingStyle.fill, color: const Color(0xFFE11D48))
          ..path(style: PaintingStyle.stroke, color: const Color(0xFFE11D48)),
      );
    });

    testWidgets('repaints when fill changes', (tester) async {
      await tester.pumpWidget(_host(const DzIcon(DzIcons.like, fill: 0)));
      await tester.pumpWidget(_host(const DzIcon(DzIcons.like, fill: 0.5)));
      expect(tester.takeException(), isNull);
    });
  });
}
