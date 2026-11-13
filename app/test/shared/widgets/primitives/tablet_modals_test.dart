import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/app_nav_rail.dart';
import 'package:dzeroth/core/widgets/tablet_modal.dart';
import 'package:dzeroth/features/account/presentation/widgets/password_prompt_dialog.dart';
import 'package:dzeroth/features/posts/presentation/bloc/composer_cubit.dart'
    show SendConflict;
import 'package:dzeroth/features/posts/presentation/widgets/cancel_scheduled_dialog.dart';
import 'package:dzeroth/features/posts/presentation/widgets/draft_dialogs.dart';
import 'package:dzeroth/features/posts/presentation/widgets/send_conflict_dialog.dart';
import 'package:dzeroth/features/profile/presentation/widgets/block_confirmation_dialog.dart';
import 'package:dzeroth/shared/widgets/user/cancel_follow_request_dialog.dart';
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
/// no bottom sheets at 600-1199 dp; phones and either flag off exactly as
/// before (ruling R-1). The desktop layout (>= 1200 dp, D1) is in
/// `desktop_modals_test.dart`.

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

    testWidgets('top and bottom insets are 24 dp, or the safe area where it '
        'is taller; a tall dialog stays clear of both', (tester) async {
      Future<EdgeInsets> insetsFor(EdgeInsets padding) async {
        late EdgeInsets insets;
        await pumpTabletModalHost(
          tester,
          width: 834,
          padding: padding,
          trigger: (context) {
            insets = const TabletModalHost(overShell: true)
                .dialogInsets(context);
            return const SizedBox();
          },
        );
        return insets;
      }

      // No safe area: 24 all round, past the 80 dp rail on the left.
      expect(
        await insetsFor(EdgeInsets.zero),
        const EdgeInsets.fromLTRB(80 + 24, 24, 24, 24),
      );
      // A short status bar (under 24 dp) does not add to the margin.
      expect(
        await insetsFor(const EdgeInsets.only(top: 20, bottom: 10)),
        const EdgeInsets.fromLTRB(80 + 24, 24, 24, 24),
      );
      // A tall one replaces it.
      expect(
        await insetsFor(const EdgeInsets.only(top: 47, bottom: 34)),
        const EdgeInsets.fromLTRB(80 + 24, 47, 24, 34),
      );

      await pumpTabletModalHost(
        tester,
        trigger: _triggers,
        width: 834,
        height: 600,
        padding: const EdgeInsets.only(top: 47, bottom: 34),
      );
      await _tap(tester, _longKey);
      final box = openDialogRect(tester);
      expect(box.top, greaterThanOrEqualTo(47 - 0.5));
      expect(box.bottom, lessThanOrEqualTo(600 - 34 + 0.5));
      expect(tester.takeException(), isNull);
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

  group('dialogs opened outside the panes', () {
    testWidgets('from the rail (the account chip): centred on the content '
        'area', (tester) async {
      await pumpTabletModalHost(
        tester,
        trigger: (_) => const SizedBox(),
        width: 834,
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

      await _tap(tester, const Key('chip'));

      _expectCentredOn(
        tester,
        tabletContentRect(const Size(834, 1194)),
        maxWidth: AppSize.alertDialogMax,
      );
    });

    testWidgets("from the root navigator's own context, with the host "
        'resolved at the button: centred on the content area', (tester) async {
      await pumpTabletModalHost(
        tester,
        width: 1024,
        trigger: (context) => TextButton(
          onPressed: () async {
            final host = TabletModalHost.of(context);
            final navigator = Navigator.of(context, rootNavigator: true);
            await Future<void>.value();
            await showSignOutDraftsDialog(navigator.context, host: host);
          },
          child: const Text('sign out'),
        ),
      );

      await tester.tap(find.text('sign out'));
      await tester.pumpAndSettle();

      _expectCentredOn(
        tester,
        tabletContentRect(const Size(1024, 1194)),
        maxWidth: AppSize.alertDialogMax,
      );
    });
  });

  group('confirm dialogs at 280-400 dp with text at 2.0', () {
    final dialogs = <String, void Function(BuildContext)>{
      'save post': (c) =>
          showSavePostDialog(c, mediaNote: 'Images are not kept.'),
      'discard drafts': (c) => showDiscardDraftsDialog(c, count: 3),
      'sign out with drafts': (c) => showSignOutDraftsDialog(c),
      'password prompt': (c) => showPasswordPromptDialog(c),
      'cancel scheduled': (c) => showCancelScheduledDialog(c),
      'block': (c) => showBlockConfirmationDialog(c),
      'cancel follow request': (c) => showCancelFollowRequestDialog(c),
      for (final conflict in SendConflict.values)
        'send conflict ${conflict.name}': (c) =>
            showSendConflictDialog(c, conflict),
    };
    const windows = [Size(1194, 834), Size(1024, 768), Size(600, 960)];
    for (final entry in dialogs.entries) {
      // One test per window: a dialog left open would block the next tap.
      for (final window in windows) {
        testWidgets('${entry.key} in ${window.width.toInt()} x '
            '${window.height.toInt()}: no overflow, centred on the content '
            'area', (tester) async {
          await pumpTabletModalHost(
            tester,
            width: window.width,
            height: window.height,
            textScale: 2,
            trigger: (context) => TextButton(
              onPressed: () => entry.value(context),
              child: const Text('open'),
            ),
          );
          await tester.tap(find.text('open'));
          await tester.pumpAndSettle();

          expect(tester.takeException(), isNull);
          expect(find.byType(Dialog), findsOneWidget);
          final box = openDialogRect(tester);
          expect(
            box.center.dx,
            closeTo(tabletContentRect(window).center.dx, 1),
          );
          expect(box.width, lessThanOrEqualTo(AppSize.alertDialogMax + 0.5));
          expect(box.bottom, lessThanOrEqualTo(window.height - 24 + 0.5));
          expect(box.top, greaterThanOrEqualTo(24 - 0.5));
        });
      }
    }
  });

  group('sheets on the tablet layout', () {
    for (final width in kBoundaryWidths) {
      // D1: from 1200 dp the desktop layout maps the sheets too, on the
      // desktop column (`desktop_modals_test.dart` covers it in full).
      final tablet = width >= 600;
      Rect area(WidgetTester tester) => width >= 1200
          ? desktopColumnRect(tester, Size(width, 1194))
          : tabletContentRect(Size(width, 1194));
      testWidgets('${width.toInt()} dp: a sheet is '
          '${tablet ? 'a dialog on the content area' : 'a bottom sheet'}', (
        tester,
      ) async {
        await pumpTabletModalHost(tester, trigger: _triggers, width: width);

        await _tap(tester, _sheetDialogKey);

        if (tablet && width >= 1200) {
          // Desktop: centred on the column, min(560, W - 48) wide (it may
          // be wider than the column less 48).
          expect(find.byType(BottomSheet), findsNothing);
          final box = openDialogRect(tester);
          expect(box.center.dx, closeTo(area(tester).center.dx, 1));
          expect(box.width, closeTo(AppSize.dialogMax, 0.5));
        } else if (tablet) {
          expect(find.byType(BottomSheet), findsNothing);
          expect(find.byType(Dialog), findsOneWidget);
          _expectCentredOn(tester, area(tester), maxWidth: AppSize.dialogMax);
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
          final content = area(tester);
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

    // 1200 dp with both flags is the desktop layout (D1,
    // `desktop_modals_test.dart`); with `ui_tablet` off it is unchanged.
    for (final (width, flags) in [
      (599.0, kTabletFlags),
      (1200.0, {kFeatureUiShell}),
    ]) {
      testWidgets('${width.toInt()} dp with $flags: unchanged (window-wide, '
          '15 dp margins)', (tester) async {
        await pumpTabletModalHost(
          tester,
          trigger: _triggers,
          width: width,
          flags: flags,
        );

        await _tap(tester, _snackKey);

        final snack = snackRect(tester);
        expect(snack.left, closeTo(15, 0.5));
        expect(snack.right, closeTo(width - 15, 0.5));
      });
    }
  });
}
