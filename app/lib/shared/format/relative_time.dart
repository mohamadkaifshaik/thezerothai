import 'package:intl/intl.dart';

/// Compact relative time for list rows: `now`, `5m`, `3h`, `2d`, then a date
/// (`Mar 4`, or `Mar 4, 2025` for another year). [now] is injected so tests
/// and widgets stay deterministic. Times in the future clamp to `now`.
String formatRelativeTime(DateTime time, DateTime now) {
  final diff = now.difference(time);
  if (diff.inSeconds < 60) return 'now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m';
  if (diff.inHours < 24) return '${diff.inHours}h';
  if (diff.inDays < 7) return '${diff.inDays}d';
  final local = time.toLocal();
  return local.year == now.toLocal().year
      ? DateFormat.MMMd().format(local)
      : DateFormat.yMMMd().format(local);
}

/// The same instant spelled out for screen readers: `5 minutes ago`.
String formatRelativeTimeSpoken(DateTime time, DateTime now) {
  final diff = now.difference(time);
  String plural(int n, String unit) => '$n $unit${n == 1 ? '' : 's'} ago';
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return plural(diff.inMinutes, 'minute');
  if (diff.inHours < 24) return plural(diff.inHours, 'hour');
  if (diff.inDays < 7) return plural(diff.inDays, 'day');
  return DateFormat.yMMMMd().format(time.toLocal());
}
