import 'package:intl/intl.dart';

/// The time a poll has left, spelled for a footer: `2 days`, `5 hours`,
/// `12 minutes`, `1 minute`. Under a minute it is `less than a minute`.
/// [closesAt] is the wire value (UTC or local); [now] is injected so widgets
/// and tests stay deterministic. A poll that already closed (the caller's
/// case) also reads `less than a minute`.
String formatPollTimeLeft(DateTime closesAt, DateTime now) {
  final left = closesAt.difference(now);
  String unit(int n, String word) => '$n $word${n == 1 ? '' : 's'}';
  if (left.inDays >= 1) return unit(left.inDays, 'day');
  if (left.inHours >= 1) return unit(left.inHours, 'hour');
  if (left.inMinutes >= 1) return unit(left.inMinutes, 'minute');
  return 'less than a minute';
}

/// `1 vote`, `12 votes`, `1.2K votes`. Counts are not live, so no copy here
/// promises more than "the last time this was read".
String formatPollVotes(int total) =>
    total == 1 ? '1 vote' : '${NumberFormat.compact().format(total)} votes';
