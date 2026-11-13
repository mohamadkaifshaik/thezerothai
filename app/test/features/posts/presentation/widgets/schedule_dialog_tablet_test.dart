import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/features/posts/presentation/widgets/schedule_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/tablet_modal_harness.dart';

/// The Schedule dialog's own date and time pickers (T8e; T2 and T7 deferred
/// them): by default the shared `showAppDatePicker` / `showAppTimePicker`
/// (T8d). On the tablet layout (600-1199 dp, both shell flags) they centre
/// where the Schedule dialog does: on the content area beside the rail when
/// it was opened from a shell page, on the window over a full-screen page.
/// The desktop layout (>= 1200 dp, D1) centres them on the shell's feed
/// column from a shell page. Phones and either flag off keep today's
/// `showDatePicker` / `showTimePicker` on the window.
void main() {
  final year = DateTime.now().year + 1;
  DateTime clock() => DateTime(year, 6, 15, 10, 7, 30);

  Widget trigger(BuildContext context) => TextButton(
    // The default pickers: no `pickDate` / `pickTime` seam.
    onPressed: () => showScheduleDialog(context, clock: clock),
    child: const Text('open'),
  );

  for (final (row, dialog) in [
    ('Date', DatePickerDialog),
    ('Time', TimePickerDialog),
  ]) {
    group('the $row row', () {
      for (final (width, inShell, flags) in [
        (360.0, true, kTabletFlags),
        (1024.0, true, kTabletFlags),
        (1024.0, false, kTabletFlags),
        // D1: the desktop layout, on the shell's feed column.
        (1440.0, true, kTabletFlags),
        (1440.0, false, kTabletFlags),
        // Desktop with `ui_tablet` off: the window, as before.
        (1440.0, true, {kFeatureUiShell}),
      ]) {
        final tablet = width >= 600 && width < 1200;
        final layout = flags.length == kTabletFlags.length;
        final onContent = tablet && inShell && layout;
        final onColumn = width >= 1200 && inShell && layout;
        testWidgets('${width.toInt()}${inShell ? '' : ', full-screen page'}'
            '${layout ? '' : ', ui_tablet off'}: centred on the '
            '${onContent
                ? 'content area'
                : onColumn
                ? 'desktop column'
                : 'window'}', (tester) async {
          await pumpTabletModalHost(
            tester,
            width: width,
            height: 1000,
            inShell: inShell,
            flags: flags,
            trigger: trigger,
          );
          await tester.tap(find.text('open'));
          await tester.pumpAndSettle();
          await tester.tap(find.bySemanticsLabel(RegExp('^$row, ')));
          await tester.pumpAndSettle();
          expect(find.byType(dialog), findsOneWidget);
          expect(tester.takeException(), isNull);
          final picker = tester.getRect(
            find
                .descendant(
                  of: find.byType(dialog),
                  matching: find.byType(Material),
                )
                .first,
          );
          final content = onColumn
              ? desktopColumnRect(tester, Size(width, 1000))
              : tabletContentRect(Size(width, 1000));
          expect(
            picker.center.dx,
            closeTo(onContent || onColumn ? content.center.dx : width / 2, 1),
          );
          if (onContent || onColumn) {
            // Never over the rail; the barrier covers it.
            expect(picker.left, greaterThanOrEqualTo(content.left));
          }
          // OK applies the pick and returns to the Schedule dialog.
          await tester.tap(find.text('OK'));
          await tester.pumpAndSettle();
          expect(find.byType(dialog), findsNothing);
          expect(find.text('Schedule'), findsOneWidget);
        });
      }
    });
  }
}
