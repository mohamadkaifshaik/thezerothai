/// Client-side mirror of the server's scheduling window (ADR-0021 D4).
///
/// The SERVER IS THE AUTHORITY: it truncates `publish_at` to the minute and
/// enforces `now + SCHEDULED_MIN_LEAD <= publish_at <= now + SCHEDULED_HORIZON`
/// by its own clock (`VALIDATION`, `field=publish_at` otherwise). These two
/// values only let the Schedule dialog disable Confirm early and say why; if
/// the server config changes they are cosmetic until updated, never wrong in a
/// way that lets a bad time through.
library;

/// `SCHEDULED_MIN_LEAD`: a post cannot be scheduled sooner than this.
const kScheduledMinLead = Duration(minutes: 2);

/// `SCHEDULED_HORIZON`: nor further ahead than this.
const kScheduledHorizon = Duration(days: 60);

/// Helper text under the date and time when the chosen time is too close.
const kScheduleTooSoonMessage = 'Pick a time at least 2 minutes from now';

/// Helper text when the chosen time is too far ahead.
const kScheduleTooFarMessage = 'Pick a time within 60 days';

/// Shown when the server refused `publish_at` although the device clock
/// thought it fine (a skewed device clock): it cannot say which bound.
const kScheduleRejectedMessage =
    'That time is not available. Pick a time between 2 minutes and 60 days '
    'from now.';

/// Why a chosen time cannot be scheduled.
enum ScheduleProblem {
  tooSoon,
  tooFar;

  String get message => switch (this) {
    ScheduleProblem.tooSoon => kScheduleTooSoonMessage,
    ScheduleProblem.tooFar => kScheduleTooFarMessage,
  };
}

/// [time] cut down to its whole minute (the server does the same). The
/// seconds and below are subtracted as a duration: rebuilding a local time
/// from its year-to-minute fields can land on another instant in a daylight
/// saving gap or overlap, subtracting cannot. Keeps the zone kind (UTC or
/// local).
DateTime truncatedToMinute(DateTime time) => time.subtract(
  Duration(
    seconds: time.second,
    milliseconds: time.millisecond,
    microseconds: time.microsecond,
  ),
);

/// What the dialog opens with: the next whole minute after [now], plus the
/// minimum lead (so Confirm is enabled at once).
DateTime defaultPublishAt(DateTime now) =>
    truncatedToMinute(now).add(const Duration(minutes: 1) + kScheduledMinLead);

/// Whether [chosen] can be scheduled at [now] (null: it can). Both are
/// compared as instants at minute precision, like the server.
ScheduleProblem? scheduleProblem(DateTime chosen, DateTime now) {
  final minute = truncatedToMinute(chosen);
  if (minute.isBefore(now.add(kScheduledMinLead))) {
    return ScheduleProblem.tooSoon;
  }
  if (minute.isAfter(now.add(kScheduledHorizon))) {
    return ScheduleProblem.tooFar;
  }
  return null;
}
