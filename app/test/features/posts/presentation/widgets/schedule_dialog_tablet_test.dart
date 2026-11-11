import 'package:dzeroth/features/posts/presentation/widgets/schedule_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/tablet_modal_harness.dart';

/// The Schedule dialog's own date and time pickers (T8e; T2 and T7 deferred
/// them): by default the shared `showAppDatePicker` / `showAppTimePicker`
/// (T8d). On the tablet layout (600-1199 dp, both shell flags) they centre
/// where the Schedule dialog does: on the content area beside the rail when
/// it was opened from a shell page, on the window over a full-screen page.
/// Phones and desktop keep today's `showDatePicker` / `showTimePicker` on the
/// window.
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
      for (final (width, inShell) in [
        (360.0, true),
        (1024.0, true),
        (1024.0, false),
        (1440.0, true),
      ]) {
        final tablet = width >= 600 && width < 1200;
        final onContent = tablet && inShell;
        testWidgets('${width.toInt()}${inShell ? '' : ', full-screen page'}: '
            'centred on the ${onContent ? 'content area' : 'window'}', (
          tester,
        ) async {
          await pumpTabletModalHost(
            tester,
            width: width,
            height: 1000,
            inShell: inShell,
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
          final content = tabletContentRect(Size(width, 1000));
          expect(
            picker.center.dx,
            closeTo(onContent ? content.center.dx : width / 2, 1),
          );
          if (onContent) {
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
