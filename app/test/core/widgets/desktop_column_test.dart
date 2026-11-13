import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/responsive_scaffold.dart';
import 'package:dzeroth/core/widgets/shell_geometry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// `ShellGeometry.desktopColumnFor` against the column `ResponsiveScaffold`
/// really lays out at >= 1200 dp (D1): the formula is what dialogs and snack
/// bars centre on, so it must not drift from the layout it mirrors.

const _bodyKey = Key('desktop-body');

/// The rail destinations of the app's shell, longest labels included.
const _labels = [
  'Home',
  'Explore',
  'Notifications',
  'Messages',
  'Lists',
  'Communities',
  'Plans',
  'History',
  'Profile',
  'More',
];

Future<void> _pump(
  WidgetTester tester, {
  required double width,
  double height = 900,
  bool master = false,
  bool side = true,
  EdgeInsets padding = EdgeInsets.zero,
  TextDirection textDirection = TextDirection.ltr,
  double textScale = 1,
  ShellLayout layout = ShellLayout.tablet,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, height);
  final fake = FakeViewPadding(
    left: padding.left,
    top: padding.top,
    right: padding.right,
    bottom: padding.bottom,
  );
  tester.view.padding = fake;
  tester.view.viewPadding = fake;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(brightness: Brightness.light),
      builder: (context, child) =>
          Directionality(textDirection: textDirection, child: child!),
      home: ResponsiveScaffold(
        selectedIndex: 0,
        onDestinationSelected: (_) {},
        layout: layout,
        redesignedRail: true,
        floatingBar: true,
        onCompose: () {},
        // The account chip is as wide as the Post pill.
        accountChipBuilder: (extended) => const SizedBox(
          width: AppSize.railPostWidth,
          height: AppSize.avatarRow,
        ),
        destinations: [
          for (final label in _labels)
            AppNavDestination(
              icon: Icons.circle_outlined,
              selectedIcon: Icons.circle,
              label: label,
            ),
        ],
        masterPane: master ? const SizedBox.expand() : null,
        sideColumn: side ? const SizedBox.expand() : null,
        body: const SizedBox.expand(key: _bodyKey),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Rect _formula(
  WidgetTester tester, {
  required double width,
  double height = 900,
  bool master = false,
  bool side = true,
  EdgeInsets padding = EdgeInsets.zero,
  TextDirection textDirection = TextDirection.ltr,
}) => ShellGeometry.desktopColumnFor(
  Size(width, height),
  padding,
  master: master,
  side: side,
  railWidth: tester.getSize(find.byType(NavigationRail)).width,
  textDirection: textDirection,
);

void _expectRect(Rect actual, Rect expected) {
  expect(actual.left, closeTo(expected.left, 0.01), reason: '$actual');
  expect(actual.width, closeTo(expected.width, 0.01), reason: '$actual');
  expect(actual.top, closeTo(expected.top, 0.01), reason: '$actual');
  expect(actual.height, closeTo(expected.height, 0.01), reason: '$actual');
}

void main() {
  const widths = [1200.0, 1280.0, 1366.0, 1440.0, 1920.0];
  const slots = {
    'with the side column': (master: false, side: true),
    'with the master pane (Settings)': (master: true, side: true),
    'with neither': (master: false, side: false),
  };

  group('desktopColumnFor equals the rendered column', () {
    for (final direction in TextDirection.values) {
      for (final MapEntry(key: name, value: slot) in slots.entries) {
        for (final width in widths) {
          testWidgets('${width.toInt()} dp $name, ${direction.name}', (
            tester,
          ) async {
            await _pump(
              tester,
              width: width,
              master: slot.master,
              side: slot.side,
              textDirection: direction,
            );
            // At least Material's 256; wider when a label needs it (270
            // here: "Notifications" in the test font).
            expect(
              tester.getSize(find.byType(NavigationRail)).width,
              greaterThanOrEqualTo(AppSize.railExtended),
            );
            _expectRect(
              tester.getRect(find.byKey(_bodyKey)),
              _formula(
                tester,
                width: width,
                master: slot.master,
                side: slot.side,
                textDirection: direction,
              ),
            );
          });
        }
      }
    }

    for (final direction in TextDirection.values) {
      for (final MapEntry(key: name, value: slot) in slots.entries) {
        testWidgets('1440 dp $name, ${direction.name}, a 44 dp notch and a '
            '20 dp inset, status bar and home indicator', (tester) async {
          const padding = EdgeInsets.fromLTRB(44, 32, 20, 21);
          await _pump(
            tester,
            width: 1440,
            master: slot.master,
            side: slot.side,
            padding: padding,
            textDirection: direction,
          );
          _expectRect(
            tester.getRect(find.byKey(_bodyKey)),
            _formula(
              tester,
              width: 1440,
              master: slot.master,
              side: slot.side,
              padding: padding,
              textDirection: direction,
            ),
          );
        });
      }
    }

    for (final width in [1200.0, 1440.0]) {
      testWidgets('${width.toInt()} dp at text scale 2.0: the rail grows '
          'with its labels and the formula follows it', (tester) async {
        await _pump(tester, width: width, textScale: 2);
        _expectRect(
          tester.getRect(find.byKey(_bodyKey)),
          _formula(tester, width: width),
        );
      });
    }
  });

  group('desktopColumnFor values', () {
    test('1440, side column: 600 wide, 59 dp left of the window centre', () {
      final rect = ShellGeometry.desktopColumnFor(
        const Size(1440, 900),
        EdgeInsets.zero,
        master: false,
        side: true,
      );
      // Row: 256 + 600 + 374 = 1230, so 105 free on each end.
      expect(rect, const Rect.fromLTWH(105 + 256, 0, 600, 900));
      expect(720 - rect.center.dx, 59);
    });

    test('1200, master pane: the column is squeezed to 594', () {
      final rect = ShellGeometry.desktopColumnFor(
        const Size(1200, 900),
        EdgeInsets.zero,
        master: true,
        side: true,
      );
      expect(rect, const Rect.fromLTWH(606, 0, 594, 900));
    });

    test('right to left mirrors the row', () {
      final rect = ShellGeometry.desktopColumnFor(
        const Size(1440, 900),
        EdgeInsets.zero,
        master: false,
        side: true,
        textDirection: TextDirection.rtl,
      );
      expect(rect, const Rect.fromLTWH(1440 - 105 - 256 - 600, 0, 600, 900));
    });
  });
}
