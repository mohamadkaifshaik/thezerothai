import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/app_back_header.dart';
import 'package:dzeroth/shared/widgets/user_list_skeleton.dart';
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
    child: Scaffold(body: SafeArea(child: child)),
  ),
);

void main() {
  group('AppBackHeader', () {
    testWidgets('shows the title and Back calls onBack', (tester) async {
      var back = 0;
      await tester.pumpWidget(
        _host(AppBackHeader(title: '@kaif', onBack: () => back++)),
      );
      expect(find.text('@kaif'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      expect(back, 1);
    });

    testWidgets(
      'titleContent replaces the title text; actions sit at the end',
      (tester) async {
        var tapped = 0;
        await tester.pumpWidget(
          _host(
            AppBackHeader(
              title: 'Sam',
              onBack: () {},
              titleContent: const Text('custom content'),
              actions: [
                IconButton(
                  tooltip: 'More',
                  icon: const Icon(Icons.info_outline),
                  onPressed: () => tapped++,
                ),
              ],
            ),
          ),
        );

        expect(find.text('custom content'), findsOneWidget);
        expect(find.text('Sam'), findsNothing);
        await tester.tap(find.byTooltip('More'));
        expect(tapped, 1);
        expect(
          tester.getTopRight(find.byTooltip('More')).dx,
          greaterThan(tester.getTopRight(find.text('custom content')).dx),
        );
      },
    );

    testWidgets('semantics: a labelled 48dp Back button and a header title', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(AppBackHeader(title: '@kaif', onBack: () {})),
      );
      expect(
        tester.getSemantics(find.byTooltip('Back')),
        isSemantics(tooltip: 'Back', isButton: true, isEnabled: true),
      );
      expect(
        tester.getSemantics(find.text('@kaif')),
        isSemantics(label: '@kaif', isHeader: true),
      );
      expect(
        tester.getSemantics(find.byTooltip('Back')).rect.height,
        greaterThanOrEqualTo(AppSpacing.minTapTarget),
      );
      handle.dispose();
    });

    for (final brightness in Brightness.values) {
      testWidgets('a long title at text x2 (${brightness.name}) ellipsizes', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          _host(
            AppBackHeader(
              title: '@a_really_quite_long_handle_name',
              onBack: () {},
              backTooltip: 'Back to profile',
            ),
            brightness: brightness,
            textScale: 2,
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.byTooltip('Back to profile'), findsOneWidget);
      });
    }
  });

  group('UserListSkeleton', () {
    testWidgets('announces itself once and shows the rows', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(const SingleChildScrollView(child: UserListSkeleton(rows: 3))),
      );
      expect(find.bySemanticsLabel('Loading people'), findsOneWidget);
      expect(find.byType(Divider), findsNWidgets(3));
      handle.dispose();
    });

    testWidgets('a custom label is announced instead', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          const UserListSkeleton(rows: 1, semanticsLabel: 'Loading blocked'),
        ),
      );
      expect(find.bySemanticsLabel('Loading blocked'), findsOneWidget);
      handle.dispose();
    });

    for (final brightness in Brightness.values) {
      testWidgets('${brightness.name}: renders without overflow', (
        tester,
      ) async {
        await tester.pumpWidget(
          _host(
            const SingleChildScrollView(child: UserListSkeleton()),
            brightness: brightness,
          ),
        );
        expect(tester.takeException(), isNull);
      });
    }
  });
}
