import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/app_form_header.dart';
import 'package:dzeroth/shared/widgets/app_gradient_button.dart';
import 'package:dzeroth/shared/widgets/app_main_column.dart';
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

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  group('AppFormHeader', () {
    testWidgets('shows Cancel, the title and the gradient action', (
      tester,
    ) async {
      var cancelled = 0;
      var acted = 0;
      await tester.pumpWidget(
        _host(
          AppFormHeader(
            title: 'Edit profile',
            onCancel: () => cancelled++,
            actionLabel: 'Save',
            onAction: () => acted++,
          ),
        ),
      );
      expect(find.text('Edit profile'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.tap(find.widgetWithText(AppGradientButton, 'Save'));
      expect((cancelled, acted), (1, 1));
    });

    testWidgets('without an action label there is no action button', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(AppFormHeader(title: 'Change handle', onCancel: () {})),
      );
      expect(find.byType(AppGradientButton), findsNothing);
      expect(find.text('Cancel'), findsOneWidget);
    });

    testWidgets('a null onAction shows the action disabled', (tester) async {
      await tester.pumpWidget(
        _host(AppFormHeader(title: 'T', onCancel: () {}, actionLabel: 'Save')),
      );
      expect(
        tester
            .widget<AppGradientButton>(find.byType(AppGradientButton))
            .onPressed,
        isNull,
      );
    });

    testWidgets('busy: Cancel off, action busy and announced', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          AppFormHeader(
            title: 'T',
            onCancel: () {},
            actionLabel: 'Save',
            onAction: () {},
            busy: true,
            busySemanticsLabel: 'Saving',
          ),
        ),
      );
      expect(
        tester.widget<TextButton>(find.byType(TextButton)).onPressed,
        isNull,
      );
      expect(
        tester.widget<AppGradientButton>(find.byType(AppGradientButton)).busy,
        isTrue,
      );
      expect(find.bySemanticsLabel('Saving'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('the title is a header; Cancel is a 48dp button', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(AppFormHeader(title: 'Edit profile', onCancel: () {})),
      );
      expect(
        tester.getSemantics(find.text('Edit profile')),
        isSemantics(label: 'Edit profile', isHeader: true),
      );
      expect(
        tester.getSemantics(find.widgetWithText(TextButton, 'Cancel')),
        isSemantics(label: 'Cancel', isButton: true, isEnabled: true),
      );
      expect(
        tester.getSize(find.widgetWithText(TextButton, 'Cancel')).height,
        greaterThanOrEqualTo(AppSpacing.minTapTarget),
      );
      handle.dispose();
    });

    for (final width in const [320.0, 390.0, 1440.0]) {
      for (final brightness in Brightness.values) {
        testWidgets(
          '${width.toInt()} wide ${brightness.name} at text x2: no overflow',
          (tester) async {
            _size(tester, Size(width, 700));
            await tester.pumpWidget(
              _host(
                AppFormHeader(
                  title: 'A rather long header title',
                  onCancel: () {},
                  actionLabel: 'Change handle',
                  onAction: () {},
                ),
                brightness: brightness,
                textScale: 2,
              ),
            );
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  });

  group('AppMainColumn', () {
    testWidgets('wide screens: at most the main-column width, centred', (
      tester,
    ) async {
      _size(tester, const Size(1440, 900));
      await tester.pumpWidget(
        _host(const AppMainColumn(child: SizedBox.expand(key: Key('c')))),
      );
      final box = tester.getRect(find.byKey(const Key('c')));
      expect(box.width, lessThanOrEqualTo(AppLayout.mainColumnMaxWidth));
      expect(box.center.dx, 720);
    });

    testWidgets('phones: the full width', (tester) async {
      _size(tester, const Size(390, 844));
      await tester.pumpWidget(
        _host(const AppMainColumn(child: SizedBox.expand(key: Key('c')))),
      );
      expect(tester.getSize(find.byKey(const Key('c'))).width, 390);
    });
  });
}
