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
/// and below in the dial, none above and below in keyboard entry), which no
/// theme reaches, so the content-area margins are applied around it, less
/// its own, and never less than the status bar at the top.
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
      // The same dialog; only a keyboard that would leave it less than its
      // keyboard-entry minimum is trimmed (see [TimePickerKeyboardRoom]).
      builder: (context, child) => TimePickerKeyboardRoom(child: child!),
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
              // Never above the status bar: in keyboard entry the picker
              // has no top inset of its own.
              math.max(
                MediaQuery.paddingOf(context).top,
                insets.top - _timePickerEnds,
              ),
              math.max(0, insets.right - _timePickerSide),
              math.max(0, insets.bottom - _timePickerEnds),
            ),
            child: TimePickerKeyboardRoom(
              child: TimePickerDialog(
                initialTime: initialTime,
                helpText: helpText,
              ),
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

/// The least height `TimePickerDialog` lays its keyboard-entry body out in
/// (Flutter's `_kTimePickerInputMinimumHeight`).
const double kTimePickerInputMinHeight = 216;

/// Keeps a `TimePickerDialog` laid out in at least its keyboard-entry
/// minimum height above the on-screen keyboard.
///
/// The dialog shrinks by the keyboard's height (`viewInsets`), and in
/// keyboard entry it asks for at least [kTimePickerInputMinHeight] plus its
/// own padding. On a landscape phone (844 x 390 with a 24 dp status bar) a
/// keyboard of 120 dp or more left less than that, and Flutter threw
/// "BoxConstraints has non-normalized height constraints". Here the
/// keyboard's height, as the dialog sees it, is trimmed to what leaves that
/// minimum: the dialog stays at its smallest size, the hour and minute
/// fields at its top stay above the keyboard, and its Cancel / OK row may
/// sit behind the keyboard until it is closed. When the room is there (any
/// window but a short one) nothing changes.
class TimePickerKeyboardRoom extends StatelessWidget {
  const TimePickerKeyboardRoom({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final media = MediaQuery.of(context);
        final keyboard = media.viewInsets.bottom;
        final padding =
            TimePickerTheme.of(context).padding
                ?.resolve(Directionality.of(context)) ??
            const EdgeInsets.all(24);
        final room = constraints.hasBoundedHeight
            ? math.max(
                0.0,
                constraints.maxHeight -
                    kTimePickerInputMinHeight -
                    padding.vertical,
              )
            : keyboard;
        // Always the same tree: a new parent would rebuild the dialog and
        // drop it from keyboard entry back to the dial.
        return MediaQuery(
          data: keyboard <= room
              ? media
              : media.copyWith(
                  viewInsets: media.viewInsets.copyWith(bottom: room),
                ),
          child: child,
        );
      },
    );
  }
}
