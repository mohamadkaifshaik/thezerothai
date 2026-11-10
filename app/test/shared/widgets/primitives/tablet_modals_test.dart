import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/app_nav_rail.dart';
import 'package:dzeroth/shared/widgets/primitives/app_dialog.dart';
import 'package:dzeroth/shared/widgets/primitives/app_sheet.dart';
import 'package:dzeroth/shared/widgets/primitives/sheet_option_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/tablet_modal_harness.dart';
import '../../../support/theme_harness.dart';

/// `showAppDialog`, `showAppMaterialDialog`, `showAppSheet` and the snack
/// bars on the tablet layout (tablet plan sections 4.2 and 5.4): centred on
/// the content area beside the rail, the barrier over the whole window,
/// no bottom sheets at 600-1199 dp; phones, desktop and either flag off
/// exactly as before (ruling R-1).

const _alertKey = Key('alert');
const _confirmKey = Key('confirm');
const _sheetDialogKey = Key('sheet-dialog');
const _sheetMenuKey = Key('sheet-menu');
const _nestedKey = Key('nested');
const _snackKey = Key('snack');
const _longKey = Key('long');

Widget _triggers(BuildContext context) {
  Widget button(Key key, String label, VoidCallback onPressed) =>
      TextButton(key: key, onPressed: onPressed, child: Text(label));
  return Wrap(
    children: [
      button(
        _alertKey,
        'alert',
        () => showAppMaterialDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Delete this post?'),
            content: const Text("This can't be undone."),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
      button(
        _confirmKey,
        'confirm',
        () => AppConfirmDialog.show(
          context,
          title: 'Leave?',
          message: 'You can join again.',
          confirmLabel: 'Leave',
        ),
      ),
      button(
        _sheetDialogKey,
        'sheet dialog',
        () => showAppSheet<String>(
          context: context,
          material: const MaterialSheetOptions(showDragHandle: true),
          builder: (context) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Appearance'),
                SheetOptionRow(
                  icon: Icons.light_mode,
                  label: 'Light',
                  onTap: () => Navigator.of(context).pop('light'),
                ),
              ],
            ),
          ),
        ),
      ),
      Builder(
        builder: (anchor) => button(
          _sheetMenuKey,
          'sheet menu',
          () => showAppSheet<String>(
            context: anchor,
            anchor: anchor,
            onTablet: AppSheetOnTablet.menu,
            material: const MaterialSheetOptions(showDragHandle: true),
            builder: (context) => SafeArea(
              child: SheetOptionRow(
                icon: Icons.repeat,
                label: 'Repost',
                onTap: () => Navigator.of(context).pop('repost'),
              ),
            ),
          ),
        ),
      ),
      button(
        _nestedKey,
        'nested',
        () => showAppMaterialDialog<void>(
          context: context,
          maxWidth: 480,
          builder: (outer) => Dialog(
            child: Builder(
              builder: (inner) => TextButton(
                onPressed: () => showAppMaterialDialog<void>(
                  context: inner,
                  builder: (_) => const AlertDialog(
                    key: Key('inner'),
                    title: Text('Delete this List?'),
                  ),
                ),
                child: const Text('open inner'),
              ),
            ),
          ),
        ),
      ),
      button(
        _longKey,
        'long',
        () => showAppDialog<void>(
          context: context,
          builder: (_) =>
              AppDialog(title: 'Long', body: Text('Line of text. ' * 400)),
        ),
      ),
      button(
        _snackKey,
        'snack',
        () => ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Copied to clipboard'))),
      ),
    ],
  );
}

Future<void> _tap(WidgetTester tester, Key key) async {
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}

void _expectCentredOn(WidgetTester tester, Rect area, {double? maxWidth}) {
  final box = openDialogRect(tester);
  expect(box.center.dx, closeTo(area.center.dx, 1), reason: '$box in $area');
  expect(box.left, greaterThanOrEqualTo(area.left + AppSpacing.lg - 0.5));
  expect(box.right, lessThanOrEqualTo(area.right - AppSpacing.lg + 0.5));
  if (maxWidth != null) {
    expect(box.width, lessThanOrEqualTo(maxWidth + 0.5));
  }
}

void main() {
  group('dialogs on the tablet layout', () {
    for (final width in kTabletMatrixWidths) {
      testWidgets('${width.toInt()} dp: a confirm dialog is centred on the '
          'content area, 280-400 wide', (tester) async {
        await pumpTabletModalHost(tester, trigger: _triggers, width: width);
        final content = tabletContentRect(Size(width, 1194));

        await _tap(tester, _alertKey);
        _expectCentredOn(tester, content, maxWidth: AppSize.alertDialogMax);
        expect(
          openDialogRect(tester).width,
          greaterThanOrEqualTo(AppSize.alertDialogMin - 0.5),
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('${width.toInt()} dp: showAppDialog is centred on the '
          'content area, min(560, C - 48) wide', (tester) async {
        await pumpTabletModalHost(tester, trigger: _triggers, width: width);
        final content = tabletContentRect(Size(width, 1194));

        await _tap(tester, _confirmKey);
        _expectCentredOn(tester, content, maxWidth: 560);
        final expected = (content.width - 48).clamp(0, 560).toDouble();
        expect(openDialogRect(tester).width, closeTo(expected, 1));
      });
    }

    testWidgets('a leading safe-area inset (landscape notch) moves the '
        'centre with the rail', (tester) async {
      const padding = EdgeInsets.only(left: 44, right: 20);
      await pumpTabletModalHost(
        tester,
        trigger: _triggers,
        width: 1024,
        height: 768,
        padding: padding,
      );
      final content = tabletContentRect(
        const Size(1024, 768),
        padding: padding,
      );

      await _tap(tester, _confirmKey);
      _expectCentredOn(tester, content, maxWidth: 560);
    });

    testWidgets('right to left: the rail is on the right and the dialog is '
        'centred on the content to its left', (tester) async {
      const padding = EdgeInsets.only(left: 20, right: 44);
      await pumpTabletModalHost(
        tester,
        trigger: _triggers,
        width: 834,
        padding: padding,
        textDirection: TextDirection.rtl,
      );
      final content = tabletContentRect(
        const Size(834, 1194),
        padding: padding,
        textDirection: TextDirection.rtl,
      );
      expect(tester.getRect(find.byType(AppNavRail)).right, closeTo(834, 1));

      await _tap(tester, _alertKey);
      _expectCentredOn(tester, content, maxWidth: AppSize.alertDialogMax);
    });

    testWidgets('a dialog opened from a dialog is centred the same way', (
      tester,
    ) async {
      await pumpTabletModalHost(tester, trigger: _triggers, width: 744);
      final content = tabletContentRect(const Size(744, 1194));

      await _tap(tester, _nestedKey);
      _expectCentredOn(tester, content, maxWidth: 480);
      await tester.tap(find.text('open inner'));
      await tester.pumpAndSettle();
      final inner = tester.getRect(
        find
            .descendant(
              of: find.byKey(const Key('inner')),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(inner.center.dx, closeTo(content.center.dx, 1));
    });

    testWidgets('the barrier covers the rail: a rail tap selects nothing', (
      tester,
    ) async {
      await pumpTabletModalHost(tester, trigger: _triggers, width: 834);
      await _tap(tester, _alertKey);
      final explore = tester.getCenter(
        find.descendant(
          of: find.byType(AppNavRail),
          matching: find.text('Explore'),
        ),
      );

      await tester.tapAt(explore);
      await tester.pumpAndSettle();

      expect(tabletHarnessSelections, isEmpty);
    });

    testWidgets('Escape closes the dialog and focus returns to the trigger', (
      tester,
    ) async {
      await pumpTabletModalHost(tester, trigger: _triggers, width: 834);
      final trigger = find.byKey(_alertKey);
      Focus.of(tester.element(find.text('alert'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      final focused = FocusManager.instance.primaryFocus?.context;
      expect(focused, isNotNull);
      expect(
        find.descendant(of: trigger, matching: find.byWidget(focused!.widget)),
        findsOneWidget,
      );
    });

    testWidgets('with the keyboard up the dialog stops above it and scrolls', (
      tester,
    ) async {
      await pumpTabletModalHost(
        tester,
        trigger: _triggers,
        width: 1194,
        height: 834,
      );
      await _tap(tester, _longKey);

      tester.view.viewInsets = const FakeViewPadding(bottom: 400);
      await tester.pumpAndSettle();

      final box = openDialogRect(tester);
      expect(box.bottom, lessThanOrEqualTo(834 - 400 - AppSpacing.lg + 0.5));
      expect(box.height, lessThanOrEqualTo(834 - 400 - 48 + 0.5));
      expect(tester.takeException(), isNull);
      expect(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.byType(Scrollable),
        ),
        findsWidgets,
      );
    });

    testWidgets('a full-screen route (no rail) centres on the window', (
      tester,
    ) async {
      await pumpTabletModalHost(
        tester,
        trigger: _triggers,
        width: 834,
        inShell: false,
      );

      await _tap(tester, _alertKey);

      _expectCentredOn(
        tester,
        const Rect.fromLTWH(0, 0, 834, 1194),
        maxWidth: AppSize.alertDialogMax,
      );
    });
  });

  group('sheets on the tablet layout', () {
    for (final width in kBoundaryWidths) {
      final tablet = width >= 600 && width < 1200;
      testWidgets('${width.toInt()} dp: a sheet is '
          '${tablet ? 'a dialog on the content area' : 'a bottom sheet'}', (
        tester,
      ) async {
        await pumpTabletModalHost(tester, trigger: _triggers, width: width);

        await _tap(tester, _sheetDialogKey);

        if (tablet) {
          expect(find.byType(BottomSheet), findsNothing);
          expect(find.byType(Dialog), findsOneWidget);
          _expectCentredOn(
            tester,
            tabletContentRect(Size(width, 1194)),
            maxWidth: AppSize.dialogMax,
          );
        } else {
          expect(find.byType(BottomSheet), findsOneWidget);
          expect(find.byType(Dialog), findsNothing);
        }
        await tester.tap(find.text('Light'));
        await tester.pumpAndSettle();
        expect(find.text('Light'), findsNothing);
      });

      testWidgets('${width.toInt()} dp: a picker is '
          '${tablet ? 'a menu at the trigger' : 'a bottom sheet'}', (
        tester,
      ) async {
        await pumpTabletModalHost(tester, trigger: _triggers, width: width);
        final anchor = tester.getRect(find.byKey(_sheetMenuKey));

        await _tap(tester, _sheetMenuKey);

        if (tablet) {
          expect(find.byType(BottomSheet), findsNothing);
          final row = tester.getRect(find.byType(SheetOptionRow));
          // Hung below the trigger (the sheet's safe area is not added).
          expect(row.top, greaterThanOrEqualTo(anchor.bottom));
          expect(row.top, lessThan(anchor.bottom + 24));
          // Clamped to the window, never over the rail.
          final content = tabletContentRect(Size(width, 1194));
          expect(row.left, greaterThanOrEqualTo(content.left));
          expect(row.right, lessThanOrEqualTo(width));
        } else {
          expect(find.byType(BottomSheet), findsOneWidget);
        }
      });
    }

    for (final flags in [
      {kFeatureUiShell},
      {kFeatureUiTablet},
      <String>{},
    ]) {
      testWidgets('834 dp with only $flags: the bottom sheet and a '
          'window-centred dialog stay', (tester) async {
        await pumpTabletModalHost(
          tester,
          trigger: _triggers,
          width: 834,
          flags: flags,
        );

        await _tap(tester, _sheetMenuKey);
        expect(find.byType(BottomSheet), findsOneWidget);
        await tester.tap(find.text('Repost'));
        await tester.pumpAndSettle();

        await _tap(tester, _alertKey);
        final box = openDialogRect(tester);
        // Centred on the window (the legacy rail and column are centred too).
        expect(box.center.dx, closeTo(834 / 2, 1));
      });
    }

    testWidgets('the menu barrier covers the rail', (tester) async {
      await pumpTabletModalHost(tester, trigger: _triggers, width: 1024);
      await _tap(tester, _sheetMenuKey);
      final explore = tester.getCenter(
        find.descendant(
          of: find.byType(AppNavRail),
          matching: find.text('Explore'),
        ),
      );

      await tester.tapAt(explore);
      await tester.pumpAndSettle();

      expect(tabletHarnessSelections, isEmpty);
      expect(find.text('Repost'), findsNothing);
    });

    testWidgets('a full-screen route on the tablet layout has no bottom '
        'sheet either', (tester) async {
      await pumpTabletModalHost(
        tester,
        trigger: _triggers,
        width: 744,
        inShell: false,
      );

      await _tap(tester, _sheetDialogKey);

      expect(find.byType(BottomSheet), findsNothing);
      _expectCentredOn(
        tester,
        const Rect.fromLTWH(0, 0, 744, 1194),
        maxWidth: AppSize.dialogMax,
      );
    });
  });

  group('snack bars', () {
    Rect snackRect(WidgetTester tester) => tester.getRect(
      find
          .descendant(
            of: find.byType(SnackBar),
            matching: find.byType(Material),
          )
          .first,
    );

    for (final width in kTabletMatrixWidths) {
      testWidgets('${width.toInt()} dp: centred over the content area, at '
          'most 560 wide', (tester) async {
        await pumpTabletModalHost(tester, trigger: _triggers, width: width);
        final content = tabletContentRect(Size(width, 1194));

        await _tap(tester, _snackKey);

        final snack = snackRect(tester);
        expect(snack.center.dx, closeTo(content.center.dx, 1));
        expect(snack.width, lessThanOrEqualTo(AppSize.dialogMax + 0.5));
        expect(snack.left, greaterThan(content.left));
      });
    }

    testWidgets('a full-screen route at 834 dp: at most 560 wide, centred on '
        'the window', (tester) async {
      await pumpTabletModalHost(
        tester,
        trigger: _triggers,
        width: 834,
        inShell: false,
      );

      await _tap(tester, _snackKey);

      final snack = snackRect(tester);
      expect(snack.center.dx, closeTo(834 / 2, 1));
      expect(snack.width, closeTo(AppSize.dialogMax, 0.5));
    });

    for (final width in [599.0, 1200.0]) {
      testWidgets('${width.toInt()} dp: unchanged (window-wide, 15 dp '
          'margins)', (tester) async {
        await pumpTabletModalHost(tester, trigger: _triggers, width: width);

        await _tap(tester, _snackKey);

        final snack = snackRect(tester);
        expect(snack.left, closeTo(15, 0.5));
        expect(snack.right, closeTo(width - 15, 0.5));
      });
    }
  });
}
