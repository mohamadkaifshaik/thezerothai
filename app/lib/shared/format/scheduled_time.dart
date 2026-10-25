import 'package:intl/intl.dart';

/// Date and time of a scheduled post in the device zone, for example
/// `Sun, Oct 25, 2026 at 9:37 PM` (`21:37` with [use24Hour]). [time] may be
/// UTC (the wire value): it is shown in the device's zone. Uses the app's
/// default intl locale, like the other date formatters.
String formatScheduledTime(DateTime time, {bool use24Hour = false}) {
  final local = time.toLocal();
  return '${formatScheduledDate(local)} at '
      '${formatScheduledClock(local, use24Hour: use24Hour)}';
}

/// The date part: `Sun, Oct 25, 2026`.
String formatScheduledDate(DateTime time) =>
    DateFormat.yMMMEd().format(time.toLocal());

/// The clock part: `9:37 PM`, or `21:37` with [use24Hour].
String formatScheduledClock(DateTime time, {bool use24Hour = false}) {
  final local = time.toLocal();
  return (use24Hour ? DateFormat.Hm() : DateFormat.jm()).format(local);
}

/// `Will send on Sun, Oct 25, 2026 at 9:37 PM`: the line under the composer
/// text, the dialog summary and the list rows.
String willSendOnText(DateTime time, {bool use24Hour = false}) =>
    'Will send on ${formatScheduledTime(time, use24Hour: use24Hour)}';

/// `Time zone: IST (UTC+05:30)` for the device zone at [time]. The zone name
/// is whatever the platform reports (an abbreviation on most, a long name on
/// Windows); the offset keeps it unambiguous.
String scheduleZoneLabel(DateTime time) {
  final local = time.toLocal();
  final offset = local.timeZoneOffset;
  final minutes = offset.inMinutes.abs();
  final sign = offset.isNegative ? '-' : '+';
  final hh = (minutes ~/ 60).toString().padLeft(2, '0');
  final mm = (minutes % 60).toString().padLeft(2, '0');
  return 'Time zone: ${local.timeZoneName} (UTC$sign$hh:$mm)';
}
