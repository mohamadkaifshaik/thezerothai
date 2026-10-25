import 'package:dzeroth/features/posts/domain/schedule_rules.dart';
import 'package:dzeroth/features/posts/presentation/bloc/schedule_dialog_cubit.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Schedule dialog's logic (CMP-D6): default, validation window and the
/// re-check on Confirm. The clock is injected.
void main() {
  final year = DateTime.now().year;
  var now = DateTime(year, 6, 15, 10, 7, 30);

  setUp(() => now = DateTime(year, 6, 15, 10, 7, 30));

  ScheduleDialogCubit make({DateTime? initial, String? notice}) {
    final cubit = ScheduleDialogCubit(
      initial: initial,
      notice: notice,
      clock: () => now,
    );
    addTearDown(cubit.close);
    return cubit;
  }

  test('opens on the next whole minute plus 2 minutes, and can confirm', () {
    final cubit = make();
    expect(cubit.state.selected, DateTime(year, 6, 15, 10, 10));
    expect(cubit.state.problem, isNull);
    expect(cubit.state.canConfirm, isTrue);
    expect(cubit.state.helper, isNull);
  });

  test('opens on an existing schedule, shown in the device zone', () {
    final cubit = make(initial: DateTime(year, 6, 16, 8, 30).toUtc());
    expect(cubit.state.selected, DateTime(year, 6, 16, 8, 30));
    expect(cubit.state.selected.isUtc, isFalse);
  });

  test('a time earlier than now + 2 minutes is too soon, Confirm is off', () {
    final cubit = make(initial: DateTime(year, 6, 15, 10, 8));
    expect(cubit.state.problem, ScheduleProblem.tooSoon);
    expect(cubit.state.canConfirm, isFalse);
    expect(cubit.state.helper, 'Pick a time at least 2 minutes from now');
    expect(cubit.confirm(), isNull);
  });

  test('a time later than now + 60 days is too far, Confirm is off', () {
    final cubit = make(initial: now.add(const Duration(days: 61)));
    expect(cubit.state.problem, ScheduleProblem.tooFar);
    expect(cubit.state.canConfirm, isFalse);
    expect(cubit.state.helper, 'Pick a time within 60 days');
    expect(cubit.confirm(), isNull);
  });

  test('the edges are accepted: 2 minutes and 60 days', () {
    final lead = make(initial: DateTime(year, 6, 15, 10, 10));
    expect(lead.state.canConfirm, isTrue);
    final edge = DateTime(year, 6, 15, 10, 7).add(kScheduledHorizon);
    final far = make(initial: edge);
    expect(far.state.canConfirm, isTrue);
  });

  test('dateChanged keeps the time of day, timeChanged keeps the date', () {
    final cubit = make(initial: DateTime(year, 6, 20, 14, 45));
    cubit.dateChanged(DateTime(year, 6, 25));
    expect(cubit.state.selected, DateTime(year, 6, 25, 14, 45));
    cubit.timeChanged(9, 5);
    expect(cubit.state.selected, DateTime(year, 6, 25, 9, 5));
  });

  test('picking a past time today is reported at once', () {
    final cubit = make();
    cubit.timeChanged(10, 8);
    expect(cubit.state.problem, ScheduleProblem.tooSoon);
  });

  test('a server notice stays until the user picks again', () {
    final cubit = make(notice: 'That time is not available.');
    expect(cubit.state.problem, isNull);
    expect(cubit.state.helper, 'That time is not available.');
    cubit.timeChanged(12, 0);
    expect(cubit.state.helper, isNull);
  });

  test('a local problem wins over a notice', () {
    final cubit = make(
      initial: DateTime(year, 6, 15, 10, 8),
      notice: 'That time is not available.',
    );
    expect(cubit.state.helper, kScheduleTooSoonMessage);
  });

  test('confirm returns the picked time as a UTC instant', () {
    final cubit = make(initial: DateTime(year, 6, 20, 14, 45));
    final result = cubit.confirm();
    expect(result, isNotNull);
    expect(result!.isUtc, isTrue);
    expect(result, DateTime(year, 6, 20, 14, 45).toUtc());
  });

  test(
    'confirm re-checks the clock: time passed while the dialog was open',
    () {
      final cubit = make();
      expect(cubit.state.canConfirm, isTrue);
      // Five minutes later the default is no longer 2 minutes away.
      now = now.add(const Duration(minutes: 5));
      expect(cubit.confirm(), isNull);
      expect(cubit.state.problem, ScheduleProblem.tooSoon);
      expect(cubit.state.canConfirm, isFalse);
    },
  );
}
