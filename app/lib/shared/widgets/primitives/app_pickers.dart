import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/widgets/tablet_modal.dart';

/// Shows the Material date picker.
///
/// Outside the tablet layout this is exactly `showDatePicker` with these
/// arguments, so phones, desktop and the 600-1199 dp layout with either
/// shell flag off do not change (ruling R-1).
///
/// On the tablet layout (`ui_shell` + `ui_tablet`, 600-1199 dp) it is the
/// same `DatePickerDialog` on the root navigator, its barrier over the whole
/// window (rail included), centred on the content area like every other
/// dialog there (tablet plan section 5.4; [TabletModalHost]). [host] is as
/// for `showAppDialog`.
Future<DateTime?> showAppDatePicker({
  required BuildContext context,
  required DateTime initialDate,
  required DateTime firstDate,
  required DateTime lastDate,
  String? helpText,
  TabletModalHost? host,
}) {
  final resolved = host ?? TabletModalHost.of(context);
  if (resolved == null) {
    return showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: firstDate,
      lastDate: lastDate,
      helpText: helpText,
    );
  }
  return showDialog<DateTime>(
    context: context,
    useRootNavigator: true,
    useSafeArea: false,
    builder: (_) => TabletModalScope(
      host: resolved,
      child: Builder(
        builder: (context) => DatePickerDialog(
          initialDate: DateUtils.dateOnly(initialDate),
          firstDate: DateUtils.dateOnly(firstDate),
          lastDate: DateUtils.dateOnly(lastDate),
          helpText: helpText,
          insetPadding: resolved.dialogInsets(context),
        ),
      ),
    ),
  );
}

/// Shows the Material time picker. As [showAppDatePicker]: today's
/// `showTimePicker` outside the tablet layout, the same dialog centred on
/// the content area on it.
///
/// `TimePickerDialog` sets its own inset padding (16 at the sides, 24 above
/// and below in the dial), which no theme reaches, so the content-area
/// margins are applied around it, less its own.
Future<TimeOfDay?> showAppTimePicker({
  required BuildContext context,
  required TimeOfDay initialTime,
  String? helpText,
  TabletModalHost? host,
}) {
  final resolved = host ?? TabletModalHost.of(context);
  if (resolved == null) {
    return showTimePicker(
      context: context,
      initialTime: initialTime,
      helpText: helpText,
    );
  }
  return showDialog<TimeOfDay>(
    context: context,
    useRootNavigator: true,
    useSafeArea: false,
    builder: (_) => TabletModalScope(
      host: resolved,
      child: Builder(
        builder: (context) {
          final insets = resolved.dialogInsets(context);
          return Padding(
            padding: EdgeInsets.fromLTRB(
              math.max(0, insets.left - _timePickerSide),
              math.max(0, insets.top - _timePickerEnds),
              math.max(0, insets.right - _timePickerSide),
              math.max(0, insets.bottom - _timePickerEnds),
            ),
            child: TimePickerDialog(
              initialTime: initialTime,
              helpText: helpText,
            ),
          );
        },
      ),
    ),
  );
}

/// `TimePickerDialog`'s own inset padding (dial mode).
const double _timePickerSide = 16;
const double _timePickerEnds = 24;
