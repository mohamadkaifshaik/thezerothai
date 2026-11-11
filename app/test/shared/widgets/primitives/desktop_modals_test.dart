import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/tablet_modal.dart';
import 'package:dzeroth/shared/widgets/primitives/app_dialog.dart';
import 'package:dzeroth/shared/widgets/primitives/app_sheet.dart';
import 'package:dzeroth/shared/widgets/primitives/sheet_option_row.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/tablet_modal_harness.dart';

/// `showAppDialog`, `showAppMaterialDialog`, `showAppSheet` and the snack
/// bars on the desktop layout (D1: `ui_shell` + `ui_tablet`, >= 1200 dp):
/// centred on the shell's feed column, `min(spec, W - 48)` wide, the
/// barrier over the whole window, no bottom sheets (the section 4.2
/// mapping); desktop with either flag off exactly as before.

const _alertKey = Key('alert');
const _confirmKey = Key('confirm');
const _sheetDialogKey = Key('sheet-dialog');
const _sheetMenuKey = Key('sheet-menu');
const _nestedKey = Key('nested');
const _snackKey = Key('snack');

const _sideKey = Key('side-column');
const _masterKey = Key('master-pane');
const _sideButtonKey = Key('side-button');
const _masterButtonKey = Key('master-button');

const _desktopWidths = [1200.0, 1280.0, 1366.0, 1440.0, 1920.0];
const _height = 900.0;

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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SheetOptionRow(
                    icon: Icons.repeat,
                    label: 'Repost',
                    onTap: () => Navigator.of(context).pop('repost'),
                  ),
                  SheetOptionRow(
                    icon: Icons.format_quote,
                    label: 'Quote',
                    onTap: () => Navigator.of(context).pop('quote'),
                  ),
                ],
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
        _snackKey,
        'snack',
        () => ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Copied to clipboard'))),
      ),
    ],
  );
}

/// The desktop panes of the harness shell: [side] the side column, [master]
/// the Settings-like master pane (which replaces it), each with a button.
Future<void> _pump(
  WidgetTester tester, {
  required double width,
  double height = _height,
  bool side = true,
  bool master = false,
  Set<String> flags = kTabletFlags,
  bool inShell = true,
  EdgeInsets padding = EdgeInsets.zero,
  TextDirection textDirection = TextDirection.ltr,
  double textScale = 1,
  Widget Function(bool extended)? accountChipBuilder,
}) => pumpTabletModalHost(
  tester,
  trigger: _triggers,
  width: width,
  height: height,
  flags: flags,
  inShell: inShell,
  padding: padding,
  textDirection: textDirection,
  textScale: textScale,
  accountChipBuilder: accountChipBuilder,
  sideColumn: side
      ? KeyedSubtree(
          key: _sideKey,
          child: Align(
            alignment: Alignment.topCenter,
            child: TextButton(
              key: _sideButtonKey,
              onPressed: () {},
              child: const Text('side'),
            ),
          ),
        )
      : null,
  masterPane: master
      ? KeyedSubtree(
          key: _masterKey,
          child: Align(
            alignment: Alignment.topCenter,
            child: TextButton(
              key: _masterButtonKey,
              onPressed: () {},
              child: const Text('master'),
            ),
          ),
        )
      : null,
);

Future<void> _tap(WidgetTester tester, Key key) async {
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}

/// The rendered feed column: the shell's body (the harness page's
/// `Scaffold`, the first below the shell's own).
Rect _renderedColumn(WidgetTester tester) => tester.getRect(
  find
      .ancestor(
        of: find.byKey(kTabletTriggerKey),
        matching: find.byType(Scaffold),
      )
      .first,
);

Rect _snackRect(WidgetTester tester) => tester.getRect(
  find
      .descendant(of: find.byType(SnackBar), matching: find.byType(Material))
      .first,
);

void main() {
  group('the column the modals centre on is the rendered column', () {
    for (final width in _desktopWidths) {
      for (final (side, master) in [(true, false), (false, true)]) {
        testWidgets('${width.toInt()} dp, '
            '${master ? 'master pane' : 'side column'}', (tester) async {
          await _pump(tester, width: width, side: side, master: master);
          expect(
            desktopColumnRect(
              tester,
              Size(width, _height),
              side: side,
              master: master,
            ),
            _renderedColumn(tester),
          );
        });
      }
    }
  });

  group('dialogs on the desktop layout', () {
    for (final width in _desktopWidths) {
      for (final (side, master) in [(true, false), (false, true)]) {
        final slot = master ? 'the master pane' : 'the side column';
        testWidgets('${width.toInt()} dp with $slot: a 560 dialog is centred '
            'on the column (min(560, W - 48))', (tester) async {
          await _pump(tester, width: width, side: side, master: master);
          final column = _renderedColumn(tester);

          await _tap(tester, _confirmKey);

          final box = openDialogRect(tester);
          expect(box.width, closeTo(AppSize.dialogMax, 0.5));
          // 1200 with the master pane: the column (606-1200) is off-centre,
          // so the dialog moves just enough to keep 24 dp from the window's
          // edge (ruling 2).
          final centre = column.center.dx.clamp(
            AppSpacing.lg + AppSize.dialogMax / 2,
            width - AppSpacing.lg - AppSize.dialogMax / 2,
          );
          expect(box.center.dx, closeTo(centre, 0.5), reason: '$box $column');
          expect(box.right, lessThanOrEqualTo(width - AppSpacing.lg + 0.5));
          expect(tester.takeException(), isNull);
        });

        testWidgets('${width.toInt()} dp with $slot: an alert dialog is '
            'centred on the column, 280-400 wide', (tester) async {
          await _pump(tester, width: width, side: side, master: master);
          final column = _renderedColumn(tester);

          await _tap(tester, _alertKey);

          final box = openDialogRect(tester);
          expect(box.center.dx, closeTo(column.center.dx, 0.5));
          expect(box.width, lessThanOrEqualTo(AppSize.alertDialogMax + 0.5));
          expect(box.width, greaterThanOrEqualTo(AppSize.alertDialogMin - 0.5));
        });
      }
    }

    testWidgets('1200 dp with the master pane: the numbers', (tester) async {
      await _pump(tester, width: 1200, side: false, master: true);
      final context = tester.element(find.byKey(kTabletTriggerKey));
      final host = TabletModalHost.of(context)!;
      final sized = host.dialogInsets(context, maxWidth: 560);
      final free = host.dialogInsets(context);
      final content = host.contentIn(context);

      expect(content, const Rect.fromLTWH(606, 0, 594, _height));
      // 560 wide, right edge at 1200 - 24.
      expect(sized, const EdgeInsets.fromLTRB(1200 - 24 - 560, 24, 24, 24));
      // Symmetric about 903: 1176 - 903 = 273 on each side.
      expect(free, const EdgeInsets.fromLTRB(903 - 273, 24, 24, 24));
    });

    testWidgets('1440 dp, right to left: the rail is on the right and the '
        'dialog is centred on the column to its left', (tester) async {
      await _pump(tester, width: 1440, textDirection: TextDirection.rtl);
      final column = _renderedColumn(tester);
      // The rail is on the column's right.
      expect(
        tester.getRect(find.byType(NavigationRail)).left,
        closeTo(column.right, 0.01),
      );
      expect(
        column,
        desktopColumnRect(
          tester,
          const Size(1440, _height),
          side: true,
          textDirection: TextDirection.rtl,
        ),
      );

      await _tap(tester, _confirmKey);

      expect(openDialogRect(tester).center.dx, closeTo(column.center.dx, 0.5));
    });

    testWidgets('1440 dp, right to left with the master pane', (tester) async {
      await _pump(
        tester,
        width: 1440,
        side: false,
        master: true,
        textDirection: TextDirection.rtl,
      );
      final column = _renderedColumn(tester);

      await _tap(tester, _alertKey);

      expect(openDialogRect(tester).center.dx, closeTo(column.center.dx, 0.5));
    });

    testWidgets('1440 dp with a 44 dp notch on the left and 20 on the right: '
        'still centred on the column', (tester) async {
      const padding = EdgeInsets.only(left: 44, right: 20, top: 30);
      await _pump(tester, width: 1440, padding: padding);
      final column = _renderedColumn(tester);
      expect(
        column.left,
        desktopColumnRect(
          tester,
          const Size(1440, _height),
          padding: padding,
          side: true,
        ).left,
      );

      await _tap(tester, _confirmKey);

      final box = openDialogRect(tester);
      expect(box.center.dx, closeTo(column.center.dx, 0.5));
      expect(box.top, greaterThanOrEqualTo(30 - 0.5));
    });

    testWidgets('1440 dp at text scale 2.0: the rail grows and the dialog '
        'follows the column', (tester) async {
      await _pump(
        tester,
        width: 1440,
        textScale: 2,
        accountChipBuilder: (_) => const Text('Alice Example'),
      );
      final column = _renderedColumn(tester);
      expect(
        column,
        desktopColumnRect(tester, const Size(1440, _height), side: true),
      );

      await _tap(tester, _confirmKey);

      expect(openDialogRect(tester).center.dx, closeTo(column.center.dx, 0.5));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a dialog opened from a dialog is centred the same way', (
      tester,
    ) async {
      await _pump(tester, width: 1440);
      final column = _renderedColumn(tester);

      await _tap(tester, _nestedKey);
      expect(openDialogRect(tester).center.dx, closeTo(column.center.dx, 0.5));
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
      expect(inner.center.dx, closeTo(column.center.dx, 0.5));
    });

    testWidgets('from the rail (the account chip): centred on the column', (
      tester,
    ) async {
      await _pump(
        tester,
        width: 1440,
        accountChipBuilder: (_) => Builder(
          builder: (chip) => IconButton(
            key: const Key('chip'),
            icon: const Icon(Icons.person),
            onPressed: () => showAppMaterialDialog<void>(
              context: chip,
              builder: (_) => const AlertDialog(title: Text('Sign out?')),
            ),
          ),
        ),
      );
      final column = _renderedColumn(tester);

      await _tap(tester, const Key('chip'));

      expect(openDialogRect(tester).center.dx, closeTo(column.center.dx, 0.5));
    });

    testWidgets('a resize while it is open: 1440 -> 1920 follows the column, '
        '-> 1024 the tablet content area', (tester) async {
      await _pump(tester, width: 1440);
      await _tap(tester, _confirmKey);

      tester.view.physicalSize = const Size(1920, _height);
      await tester.pumpAndSettle();
      expect(
        openDialogRect(tester).center.dx,
        closeTo(_renderedColumn(tester).center.dx, 0.5),
      );

      tester.view.physicalSize = const Size(1024, _height);
      await tester.pumpAndSettle();
      expect(
        openDialogRect(tester).center.dx,
        closeTo(tabletContentRect(const Size(1024, _height)).center.dx, 0.5),
      );
    });

    testWidgets('the barrier covers the rail: a rail tap selects nothing', (
      tester,
    ) async {
      await _pump(tester, width: 1440);
      await _tap(tester, _alertKey);
      final explore = tester.getCenter(
        find.descendant(
          of: find.byType(NavigationRail),
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
      await _pump(tester, width: 1440);
      Focus.of(tester.element(find.text('confirm'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsNothing);
      final focused = FocusManager.instance.primaryFocus?.context;
      expect(focused, isNotNull);
      expect(
        find.descendant(
          of: find.byKey(_confirmKey),
          matching: find.byWidget(focused!.widget),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a full-screen route (no rail) centres on the window, '
        'min(560, W - 48) wide', (tester) async {
      await _pump(tester, width: 1440, inShell: false);

      await _tap(tester, _confirmKey);

      final box = openDialogRect(tester);
      expect(box.center.dx, closeTo(720, 0.5));
      expect(box.width, closeTo(AppSize.dialogMax, 0.5));
    });
  });

  group('sheets on the desktop layout (the section 4.2 mapping)', () {
    for (final width in _desktopWidths) {
      testWidgets('${width.toInt()} dp: a form sheet is a 560 dialog on the '
          'column', (tester) async {
        await _pump(tester, width: width);
        final column = _renderedColumn(tester);

        await _tap(tester, _sheetDialogKey);

        expect(find.byType(BottomSheet), findsNothing);
        expect(find.byType(Dialog), findsOneWidget);
        final box = openDialogRect(tester);
        expect(box.center.dx, closeTo(column.center.dx, 0.5));
        expect(box.width, closeTo(AppSize.dialogMax, 0.5));
        await tester.tap(find.text('Light'));
        await tester.pumpAndSettle();
        expect(find.text('Light'), findsNothing);
      });

      testWidgets('${width.toInt()} dp: a picker sheet is a menu hung from '
          'its trigger', (tester) async {
        await _pump(tester, width: width);
        final anchor = tester.getRect(find.byKey(_sheetMenuKey));

        await _tap(tester, _sheetMenuKey);

        expect(find.byType(BottomSheet), findsNothing);
        expect(find.byType(Dialog), findsNothing);
        final row = tester.getRect(find.byType(SheetOptionRow).first);
        expect(row.top, greaterThanOrEqualTo(anchor.bottom));
        expect(row.top, lessThan(anchor.bottom + 24));
        // Its start edge on the trigger's.
        expect(row.left, closeTo(anchor.left + AppSpacing.xs, 1));
      });
    }

    testWidgets('1440 dp, right to left: the menu hangs from the trigger\'s '
        'start (right) edge', (tester) async {
      await _pump(tester, width: 1440, textDirection: TextDirection.rtl);
      final anchor = tester.getRect(find.byKey(_sheetMenuKey));

      await _tap(tester, _sheetMenuKey);

      final row = tester.getRect(find.byType(SheetOptionRow).first);
      expect(row.right, closeTo(anchor.right - AppSpacing.xs, 1));
    });

    testWidgets('the menu: hover highlights a row, arrows move, Escape '
        'closes and focus returns to the trigger', (tester) async {
      await _pump(tester, width: 1440);
      Focus.of(tester.element(find.text('sheet menu'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Repost'), findsOneWidget);

      final mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        pointer: 1,
      );
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: const Offset(1, 1));
      await tester.pump();
      await mouse.moveTo(tester.getCenter(find.text('Quote')));
      await tester.pumpAndSettle();
      // The hovered row paints the theme's hover highlight (`InkWell`; the
      // click cursor is web's, `adaptiveClickable`).
      // The ink layer the row's highlight is painted on (the menu's own
      // `Material`).
      RenderObject? ink = tester.renderObject(find.text('Quote'));
      while (ink != null &&
          ink.runtimeType.toString() != '_RenderInkFeatures') {
        ink = ink.parent;
      }
      expect(ink, isNotNull);
      final theme = Theme.of(tester.element(find.text('Quote')));
      final hover = theme.hoverColor;
      // The first row holds the focus (its highlight first), the hovered
      // second row its hover highlight.
      expect(
        ink,
        paints
          ..rect(color: theme.focusColor)
          ..rect(color: hover),
      );
      await mouse.moveTo(const Offset(1, 1));
      await tester.pumpAndSettle();
      expect(ink, isNot(paints..rect(color: hover)));

      // Focus starts on the first row; Down moves to the next.
      final first = FocusManager.instance.primaryFocus;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, isNot(first));

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Repost'), findsNothing);
      final focused = FocusManager.instance.primaryFocus?.context;
      expect(
        find.descendant(
          of: find.byKey(_sheetMenuKey),
          matching: find.byWidget(focused!.widget),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a full-screen route at 1440 dp has no bottom sheet either', (
      tester,
    ) async {
      await _pump(tester, width: 1440, inShell: false);

      await _tap(tester, _sheetDialogKey);

      expect(find.byType(BottomSheet), findsNothing);
      expect(openDialogRect(tester).center.dx, closeTo(720, 0.5));
    });

    for (final flags in [
      {kFeatureUiShell},
      {kFeatureUiTablet},
      <String>{},
    ]) {
      for (final width in [1200.0, 1440.0]) {
        testWidgets('${width.toInt()} dp with only $flags: the bottom sheet '
            'and the window-centred dialog stay', (tester) async {
          await _pump(tester, width: width, flags: flags);

          await _tap(tester, _sheetMenuKey);
          expect(find.byType(BottomSheet), findsOneWidget);
          await tester.tap(find.text('Repost'));
          await tester.pumpAndSettle();

          await _tap(tester, _sheetDialogKey);
          expect(find.byType(BottomSheet), findsOneWidget);
          await tester.tap(find.text('Light'));
          await tester.pumpAndSettle();

          await _tap(tester, _alertKey);
          expect(openDialogRect(tester).center.dx, closeTo(width / 2, 1));
        });
      }
    }
  });

  group('snack bars on the desktop layout', () {
    for (final width in _desktopWidths) {
      for (final (side, master) in [(true, false), (false, true)]) {
        testWidgets('${width.toInt()} dp, '
            '${master ? 'master pane' : 'side column'}: over the column, '
            'at most 560 wide', (tester) async {
          await _pump(tester, width: width, side: side, master: master);
          final column = _renderedColumn(tester);

          await _tap(tester, _snackKey);

          final snack = _snackRect(tester);
          expect(snack.center.dx, closeTo(column.center.dx, 0.5));
          // min(560, column - 30): Material's 15 dp side margins inside a
          // column under 590 (1200 with the side column: 570).
          expect(
            snack.width,
            closeTo(
              (column.width - 30).clamp(0, AppSize.dialogMax).toDouble(),
              0.5,
            ),
          );
        });
      }
    }

    testWidgets('1440 dp, right to left: over the column', (tester) async {
      await _pump(tester, width: 1440, textDirection: TextDirection.rtl);
      final column = _renderedColumn(tester);

      await _tap(tester, _snackKey);

      expect(_snackRect(tester).center.dx, closeTo(column.center.dx, 0.5));
    });

    testWidgets('1440 dp at text scale 2.0: over the column beside the wider '
        'rail', (tester) async {
      await _pump(tester, width: 1440, textScale: 2);
      final column = _renderedColumn(tester);
      expect(
        tester.getSize(find.byType(NavigationRail)).width,
        greaterThan(AppSize.railExtended),
      );

      await _tap(tester, _snackKey);

      expect(_snackRect(tester).center.dx, closeTo(column.center.dx, 0.5));
    });

    testWidgets('a full-screen route at 1440 dp: 560 wide, centred on the '
        'window', (tester) async {
      await _pump(tester, width: 1440, inShell: false);

      await _tap(tester, _snackKey);

      final snack = _snackRect(tester);
      expect(snack.center.dx, closeTo(720, 0.5));
      expect(snack.width, closeTo(AppSize.dialogMax, 0.5));
    });

    for (final flags in [
      {kFeatureUiShell},
      {kFeatureUiTablet},
      <String>{},
    ]) {
      testWidgets('1440 dp with only $flags: unchanged (window-wide, 15 dp '
          'margins)', (tester) async {
        await _pump(tester, width: 1440, flags: flags);

        await _tap(tester, _snackKey);

        final snack = _snackRect(tester);
        expect(snack.left, closeTo(15, 0.5));
        expect(snack.right, closeTo(1440 - 15, 0.5));
      });
    }
  });

  group('keyboard: Tab moves through the rail, the master pane, the column '
      'and the side column in turn', () {
    /// Which pane each focus stop of a full Tab cycle is in.
    Future<List<String>> tabCycle(WidgetTester tester) async {
      final rail = find.byType(NavigationRail);
      String paneOf(BuildContext context) {
        bool inside(Finder f) =>
            f.evaluate().isNotEmpty &&
            find
                .descendant(of: f, matching: find.byWidget(context.widget))
                .evaluate()
                .isNotEmpty;
        if (inside(rail)) return 'rail';
        if (inside(find.byKey(_masterKey))) return 'master';
        if (inside(find.byKey(_sideKey))) return 'side';
        if (inside(find.byKey(kTabletTriggerKey))) return 'column';
        return 'other';
      }

      final stops = <String>[];
      // Start before the first stop.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      for (var i = 0; i < 40; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final context = FocusManager.instance.primaryFocus?.context;
        if (context == null) continue;
        final pane = paneOf(context);
        if (stops.isNotEmpty && stops.last == pane) continue;
        stops.add(pane);
      }
      return stops;
    }

    /// The first full pass through the panes, from the rail.
    List<String> firstPass(List<String> stops) {
      final start = stops.indexOf('rail');
      final pass = <String>[];
      for (final s in stops.skip(start)) {
        if (pass.contains(s)) break;
        pass.add(s);
      }
      return pass;
    }

    testWidgets('1440 dp with the master pane: rail, master, column', (
      tester,
    ) async {
      await _pump(tester, width: 1440, side: false, master: true);
      final stops = await tabCycle(tester);
      expect(firstPass(stops), ['rail', 'master', 'column']);
    });

    testWidgets('1440 dp with the side column: rail, column, side', (
      tester,
    ) async {
      await _pump(tester, width: 1440);
      final stops = await tabCycle(tester);
      expect(firstPass(stops), ['rail', 'column', 'side']);
    });

    testWidgets('1440 dp, right to left, with the master pane: rail, master, '
        'column', (tester) async {
      await _pump(
        tester,
        width: 1440,
        side: false,
        master: true,
        textDirection: TextDirection.rtl,
      );
      final stops = await tabCycle(tester);
      expect(firstPass(stops), ['rail', 'master', 'column']);
    });
  });
}
