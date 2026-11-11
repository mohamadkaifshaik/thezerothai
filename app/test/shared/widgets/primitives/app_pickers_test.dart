import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pickers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/tablet_modal_harness.dart';
import '../../../support/theme_harness.dart' show kBoundaryWidths;

/// The date and time pickers on the tablet layout (T8d; T2 deferred them):
/// the same Material dialogs, on the root navigator and centred on the
/// content area at 600-1199 with both shell flags, and on the desktop
/// shell's feed column from 1200 (D1); today's `showDatePicker` /
/// `showTimePicker` everywhere else.
void main() {
  Widget trigger(String kind, ValueSetter<Object?> onResult) => Builder(
    builder: (context) => TextButton(
      onPressed: () async {
        final now = DateTime.now();
        onResult(
          kind == 'date'
              ? await showAppDatePicker(
                  context: context,
                  initialDate: now,
                  firstDate: now,
                  lastDate: now.add(const Duration(days: 30)),
                  helpText: 'Date',
                )
              : await showAppTimePicker(
                  context: context,
                  initialTime: const TimeOfDay(hour: 9, minute: 30),
                  helpText: 'Time',
                ),
        );
      },
      child: Text('open $kind'),
    ),
  );

  Type dialogType(String kind) =>
      kind == 'date' ? DatePickerDialog : TimePickerDialog;

  for (final kind in ['date', 'time']) {
    group('$kind picker', () {
      for (final w in [...kBoundaryWidths, 1440.0]) {
        final tablet = w >= 600 && w < 1200;
        final desktop = w >= 1200;
        testWidgets('at ${w.toInt()}: centred on the '
            '${tablet
                ? 'content area'
                : desktop
                ? 'desktop column'
                : 'window'}', (tester) async {
          await pumpTabletModalHost(
            tester,
            width: w,
            height: 1000,
            trigger: (_) => trigger(kind, (_) {}),
          );
          await tester.tap(find.text('open $kind'));
          await tester.pumpAndSettle();
          expect(find.byType(dialogType(kind)), findsOneWidget);
          expect(tester.takeException(), isNull);
          final centre = tablet
              ? tabletContentRect(Size(w, 1000)).center.dx
              : desktop
              // D1: the shell's feed column (the harness has no side
              // column).
              ? desktopColumnRect(tester, Size(w, 1000)).center.dx
              : w / 2;
          expect(openDialogRect(tester).center.dx, closeTo(centre, 1));
        });
      }

      // Desktop with either flag off: today's picker on the window.
      for (final flags in [
        {kFeatureUiShell},
        {kFeatureUiTablet},
      ]) {
        testWidgets('at 1200 with only $flags: centred on the window', (
          tester,
        ) async {
          await pumpTabletModalHost(
            tester,
            width: 1200,
            height: 1000,
            flags: flags,
            trigger: (_) => trigger(kind, (_) {}),
          );
          await tester.tap(find.text('open $kind'));
          await tester.pumpAndSettle();
          expect(find.byType(dialogType(kind)), findsOneWidget);
          expect(openDialogRect(tester).center.dx, closeTo(600, 1));
        });
      }

      // Phones in landscape are band B (rail density R3): the picker fits the
      // short window, on the content area, as it does with the shell flags
      // off on the window.
      for (final frame in const [Size(844, 390), Size(932, 430)]) {
        for (final tabletFlags in [true, false]) {
          testWidgets('${frame.width.toInt()} x ${frame.height.toInt()}, '
              '${tabletFlags ? 'tablet layout' : 'ui_tablet off'}: no '
              'overflow, inside the window', (tester) async {
            await pumpTabletModalHost(
              tester,
              width: frame.width,
              height: frame.height,
              flags: tabletFlags ? kTabletFlags : {kFeatureUiShell},
              trigger: (_) => trigger(kind, (_) {}),
            );
            await tester.tap(find.text('open $kind'));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            final rect = openDialogRect(tester);
            expect(rect.top, greaterThanOrEqualTo(0));
            expect(rect.bottom, lessThanOrEqualTo(frame.height));
            final content = tabletContentRect(frame);
            expect(
              rect.center.dx,
              closeTo(tabletFlags ? content.center.dx : frame.width / 2, 1),
            );
          });
        }
      }

      if (kind == 'time') {
        // UX review of T8d: in keyboard entry the time picker has no inset
        // of its own, so on a landscape phone with the keyboard up it must
        // still stop at the status bar.
        testWidgets('844 x 390, status bar 24, the dial: no overflow, below '
            'the status bar', (tester) async {
          await pumpTabletModalHost(
            tester,
            width: 844,
            height: 390,
            padding: const EdgeInsets.only(top: 24),
            trigger: (_) => trigger(kind, (_) {}),
          );
          await tester.tap(find.text('open $kind'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final rect = openDialogRect(tester);
          expect(rect.top, greaterThanOrEqualTo(24));
          expect(rect.bottom, lessThanOrEqualTo(390));
        });

        // (A taller keyboard, 120 dp at a 24 dp status bar, makes Flutter's
        // own TimePickerDialog throw non-normalized constraints on the
        // window path too, with the shell flags off: not this helper's.)
        for (final (top, keyboard) in const <(double, double)>[
          (24, 100),
          (40, 80),
        ]) {
          testWidgets('844 x 390, status bar $top, keyboard $keyboard, '
              'keyboard entry: the dialog stays below the status bar', (
            tester,
          ) async {
            await pumpTabletModalHost(
              tester,
              width: 844,
              height: 390,
              padding: EdgeInsets.only(top: top),
              trigger: (_) => trigger(kind, (_) {}),
            );
            await tester.tap(find.text('open $kind'));
            await tester.pumpAndSettle();
            await tester.tap(find.byIcon(Icons.keyboard_outlined));
            await tester.pumpAndSettle();
            // The keyboard comes up for the hour field.
            tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            final rect = openDialogRect(tester);
            expect(rect.top, greaterThanOrEqualTo(top));
            expect(
              rect.center.dx,
              closeTo(tabletContentRect(const Size(844, 390)).center.dx, 1),
            );
          });
        }
      }

      for (final flags in [
        {kFeatureUiShell},
        {kFeatureUiTablet},
        <String>{},
      ]) {
        testWidgets('flags $flags at 834: the window centre, as today', (
          tester,
        ) async {
          await pumpTabletModalHost(
            tester,
            flags: flags,
            trigger: (_) => trigger(kind, (_) {}),
          );
          await tester.tap(find.text('open $kind'));
          await tester.pumpAndSettle();
          expect(openDialogRect(tester).center.dx, closeTo(417, 1));
        });
      }

      testWidgets('RTL at 1024 with side insets: centred on the content area '
          'on the left of the rail', (tester) async {
        const padding = EdgeInsets.only(left: 30, right: 44);
        await pumpTabletModalHost(
          tester,
          width: 1024,
          height: 768,
          padding: padding,
          textDirection: TextDirection.rtl,
          trigger: (_) => trigger(kind, (_) {}),
        );
        await tester.tap(find.text('open $kind'));
        await tester.pumpAndSettle();
        final content = tabletContentRect(
          const Size(1024, 768),
          padding: padding,
          textDirection: TextDirection.rtl,
        );
        final rect = openDialogRect(tester);
        expect(rect.center.dx, closeTo(content.center.dx, 1));
        expect(rect.right, lessThanOrEqualTo(content.right - 24 + 1));
        expect(tester.takeException(), isNull);
      });

      testWidgets('on the tablet layout the barrier covers the rail, Escape '
          'closes it, and the answer comes back', (tester) async {
        Object? result = 'unset';
        await pumpTabletModalHost(
          tester,
          trigger: (_) => trigger(kind, (r) => result = r),
        );
        await tester.tap(find.text('open $kind'));
        await tester.pumpAndSettle();
        // A tap on the rail lands on the barrier, which closes the picker
        // without selecting the destination.
        await tester.tapAt(const Offset(AppSize.railCompact / 2, 300));
        await tester.pumpAndSettle();
        expect(tabletHarnessSelections, isEmpty);
        expect(find.byType(dialogType(kind)), findsNothing);
        expect(result, isNull);

        await tester.tap(find.text('open $kind'));
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(dialogType(kind)), findsNothing);

        await tester.tap(find.text('open $kind'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        expect(result, kind == 'date' ? isA<DateTime>() : isA<TimeOfDay>());
      });

      testWidgets('text scale 2.0 at 600 x 960: no overflow, inside the '
          'content area', (tester) async {
        await pumpTabletModalHost(
          tester,
          width: 600,
          height: 960,
          textScale: 2,
          trigger: (_) => trigger(kind, (_) {}),
        );
        await tester.tap(find.text('open $kind'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final rect = openDialogRect(tester);
        expect(rect.left, greaterThanOrEqualTo(AppSize.railCompact + 24 - 1));
        expect(rect.right, lessThanOrEqualTo(600 - 24 + 1));
      });
    });
  }
}
