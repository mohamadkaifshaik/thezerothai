import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/app_section_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(
  Widget child, {
  Brightness brightness = Brightness.dark,
  double textScale = 1,
}) => MaterialApp(
  theme: buildAppTheme(brightness: brightness),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

void main() {
  group('AppSectionHeader', () {
    testWidgets('shows title and subtitle in dark and light', (tester) async {
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          _host(
            const AppSectionHeader(title: 'Your posts', subtitle: '27 posts'),
            brightness: brightness,
          ),
        );
        expect(find.text('Your posts'), findsOneWidget);
        expect(find.text('27 posts'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('announces the title as a header', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(const AppSectionHeader(title: 'Your posts')),
      );

      expect(
        tester.getSemantics(find.text('Your posts')),
        matchesSemantics(label: 'Your posts', isHeader: true),
      );
      handle.dispose();
    });

    testWidgets('action calls back and is at least 48 dp tall', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(
          AppSectionHeader(
            title: 'Your posts',
            actionLabel: 'View all',
            onAction: () => taps++,
          ),
        ),
      );

      await tester.tap(find.text('View all'));
      expect(taps, 1);
      expect(
        tester.getSize(find.byType(TextButton)).height,
        greaterThanOrEqualTo(AppSpacing.minTapTarget),
      );
    });

    testWidgets('has no action without one', (tester) async {
      await tester.pumpWidget(
        _host(const AppSectionHeader(title: 'Your posts')),
      );
      expect(find.byType(TextButton), findsNothing);
    });

    testWidgets('long title, subtitle and action at 2.0 scale and 320 dp '
        'do not overflow', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          _host(
            AppSectionHeader(
              title: 'A rather long section title that needs to wrap',
              subtitle: 'A subtitle that is also long enough to wrap lines',
              actionLabel: 'View everything',
              onAction: () {},
            ),
            brightness: brightness,
            textScale: 2,
          ),
        );
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('can be built with const', (tester) async {
      // Compiles only while the constructor stays const.
      const header = AppSectionHeader(title: 'const', subtitle: 'too');
      await tester.pumpWidget(_host(header));
      expect(find.text('const'), findsOneWidget);
    });
  });
}
