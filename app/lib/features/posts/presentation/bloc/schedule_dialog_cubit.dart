import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../domain/schedule_rules.dart';

/// What the Schedule dialog shows: the time picked so far and the clock
/// reading it was last checked against.
@immutable
class ScheduleDialogState {
  const ScheduleDialogState({
    required this.selected,
    required this.now,
    this.notice,
  });

  /// The picked date and time, in the device zone, at minute precision.
  final DateTime selected;

  /// The clock when the state was made (the clock moves on, so the check is
  /// repeated on every pick and on Confirm).
  final DateTime now;

  /// Text from a server refusal of the time ("that time is not available")
  /// that stays up until the user picks again.
  final String? notice;

  /// Why [selected] cannot be scheduled (null: it can).
  ScheduleProblem? get problem => scheduleProblem(selected, now);

  bool get canConfirm => problem == null;

  /// The helper text under the pickers: the local problem first, then a
  /// server [notice].
  String? get helper => problem?.message ?? notice;
}

/// The state of the Schedule dialog (CMP-D6): which date and time are picked
/// and whether Confirm may be pressed. Pure logic over an injected clock; the
/// dialog widget owns only the picker calls.
class ScheduleDialogCubit extends Cubit<ScheduleDialogState> {
  /// Opens on [initial] (a UTC or local instant: the schedule already set),
  /// or on [defaultPublishAt] when there is none. [notice] is shown under the
  /// pickers until the time changes.
  ScheduleDialogCubit({
    DateTime? initial,
    String? notice,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       super(_initialState(initial, notice, clock ?? DateTime.now));

  final DateTime Function() _clock;

  static ScheduleDialogState _initialState(
    DateTime? initial,
    String? notice,
    DateTime Function() clock,
  ) {
    final now = clock();
    return ScheduleDialogState(
      selected: truncatedToMinute((initial ?? defaultPublishAt(now)).toLocal()),
      now: now,
      notice: notice,
    );
  }

  /// A date was picked: keep the time of day.
  void dateChanged(DateTime date) {
    final current = state.selected;
    _select(
      DateTime(date.year, date.month, date.day, current.hour, current.minute),
    );
  }

  /// A time of day was picked: keep the date.
  void timeChanged(int hour, int minute) {
    final current = state.selected;
    _select(DateTime(current.year, current.month, current.day, hour, minute));
  }

  void _select(DateTime selected) {
    emit(ScheduleDialogState(selected: selected, now: _clock()));
  }

  /// The time to schedule as a UTC instant, or null (and a refreshed check)
  /// when it can no longer be scheduled because time has passed.
  DateTime? confirm() {
    final now = _clock();
    if (scheduleProblem(state.selected, now) != null) {
      emit(
        ScheduleDialogState(
          selected: state.selected,
          now: now,
          notice: state.notice,
        ),
      );
      return null;
    }
    return state.selected.toUtc();
  }
}
