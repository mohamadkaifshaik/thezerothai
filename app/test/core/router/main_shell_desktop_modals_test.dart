import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/app_nav_rail.dart';
import 'package:dzeroth/core/widgets/responsive_scaffold.dart';
import 'package:dzeroth/core/widgets/shell_geometry.dart';
import 'package:dzeroth/shared/widgets/primitives/app_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/shells_harness.dart';
import '../../support/tablet_modal_harness.dart' show openDialogRect;

/// D1 end to end: the real `MainShell` at >= 1200 dp passes both flags to
/// `ResponsiveScaffold`, so a dialog and a snack bar opened from the shell
/// centre on its feed column, which is where `desktopColumnFor` puts it (the
/// side column on most pages, the master pane on Settings). With
/// `ui_tablet` off the desktop shell is today's: centred on the window.

const _tabletFlags = {...kShellFlags, kFeatureUiTablet};

/// The shell's feed column as rendered: the first 600 dp cap under the
/// scaffold.
Rect _renderedColumn(WidgetTester tester) => tester.getRect(
  find
      .descendant(
        of: find.byType(ResponsiveScaffold),
        matching: find.byWidgetPredicate(
          (w) =>
              w is ConstrainedBox &&
              w.constraints.maxWidth == AppSize.contentMax,
        ),
      )
      .first,
);

/// A context inside the shell (its rail).
BuildContext _shell(WidgetTester tester) =>
    tester.element(find.byType(NavigationRail));

Future<void> _pump(
  WidgetTester tester, {
  required double width,
  String location = AppRouter.creatorStudioPath,
  Set<String> flags = _tabletFlags,
  TextDirection textDirection = TextDirection.ltr,
}) async {
  await pumpShellsApp(
    tester,
    flags: flags,
    location: location,
    size: Size(width, 900),
    textDirection: textDirection,
  );
}

void main() {
  for (final width in [1200.0, 1440.0, 1920.0]) {
    for (final (location, master) in [
      (AppRouter.creatorStudioPath, false),
      (AppRouter.settingsPath, true),
    ]) {
      testWidgets('${width.toInt()} dp on $location: the formula is the '
          'rendered column, and a dialog and a snack bar centre on it', (
        tester,
      ) async {
        await _pump(tester, width: width, location: location);
        final column = _renderedColumn(tester);
        expect(
          column,
          ShellGeometry.desktopColumnFor(
            Size(width, 900),
            EdgeInsets.zero,
            master: master,
            side: !master,
            railWidth: tester.getSize(find.byType(NavigationRail)).width,
          ),
        );

        AppConfirmDialog.show(
          _shell(tester),
          title: 'Leave?',
          message: 'You can join again.',
          confirmLabel: 'Leave',
        );
        await tester.pumpAndSettle();
        final box = openDialogRect(tester);
        // min(560, W - 48), moved inside the window's 24 dp margin where
        // the column is off-centre (1200 with the master pane).
        final centre = column.center.dx.clamp(
          AppSpacing.lg + AppSize.dialogMax / 2,
          width - AppSpacing.lg - AppSize.dialogMax / 2,
        );
        expect(box.center.dx, closeTo(centre, 0.5));
        expect(box.width, closeTo(AppSize.dialogMax, 0.5));
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        ScaffoldMessenger.of(_shell(tester))
            .showSnackBar(const SnackBar(content: Text('Copied')));
        await tester.pumpAndSettle();
        final snack = tester.getRect(
          find
              .descendant(
                of: find.byType(SnackBar),
                matching: find.byType(Material),
              )
              .first,
        );
        expect(snack.center.dx, closeTo(column.center.dx, 0.5));
      });
    }
  }

  testWidgets('1440 dp, right to left: on the column left of the rail', (
    tester,
  ) async {
    await _pump(tester, width: 1440, textDirection: TextDirection.rtl);
    final column = _renderedColumn(tester);
    expect(
      column,
      ShellGeometry.desktopColumnFor(
        const Size(1440, 900),
        EdgeInsets.zero,
        master: false,
        side: true,
        railWidth: tester.getSize(find.byType(NavigationRail)).width,
        textDirection: TextDirection.rtl,
      ),
    );

    AppConfirmDialog.show(
      _shell(tester),
      title: 'Leave?',
      message: 'You can join again.',
      confirmLabel: 'Leave',
    );
    await tester.pumpAndSettle();
    expect(openDialogRect(tester).center.dx, closeTo(column.center.dx, 0.5));
  });

  testWidgets('1440 dp with ui_tablet off: centred on the window, as before', (
    tester,
  ) async {
    await _pump(tester, width: 1440, flags: kShellFlags);

    AppConfirmDialog.show(
      _shell(tester),
      title: 'Leave?',
      message: 'You can join again.',
      confirmLabel: 'Leave',
    );
    await tester.pumpAndSettle();
    expect(openDialogRect(tester).center.dx, closeTo(720, 0.5));
  });

  // Review fix 1: the host captured at 1024 knows nothing of the desktop
  // panes. Widened past 1200 over Settings, the dialog follows the shell's
  // live master pane and rail, not a default side column.
  for (final (from, to) in [(1024.0, 1440.0), (834.0, 1280.0)]) {
    testWidgets('a dialog opened at ${from.toInt()} on Settings and widened to '
        '${to.toInt()} lands on the column beside the master pane', (
      tester,
    ) async {
      await _pump(tester, width: from, location: AppRouter.settingsPath);
      AppConfirmDialog.show(
        tester.element(find.byType(AppNavRail)),
        title: 'Leave?',
        message: 'You can join again.',
        confirmLabel: 'Leave',
      );
      await tester.pumpAndSettle();

      tester.view.physicalSize = Size(to, 900);
      await tester.pumpAndSettle();

      final column = _renderedColumn(tester);
      // The master pane is before the column: a side-column guess would put
      // the dialog about 360 dp to its left.
      expect(
        column.left,
        greaterThan(tester.getRect(find.byType(NavigationRail)).right + 300),
      );
      expect(openDialogRect(tester).center.dx, closeTo(column.center.dx, 0.5));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a dialog opened at 1440 on Settings and narrowed to 1024 '
      'follows the tablet content area', (tester) async {
    await _pump(tester, width: 1440, location: AppRouter.settingsPath);
    AppConfirmDialog.show(
      _shell(tester),
      title: 'Leave?',
      message: 'You can join again.',
      confirmLabel: 'Leave',
    );
    await tester.pumpAndSettle();

    tester.view.physicalSize = const Size(1024, 900);
    await tester.pumpAndSettle();

    expect(
      openDialogRect(tester).center.dx,
      closeTo(80 + (1024 - 80) / 2, 0.5),
    );
  });
}
