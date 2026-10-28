import 'package:intl/intl.dart';

import '../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import '../../../shared/format/scheduled_time.dart';

/// One row of the conversation list, in list order: index 0 is the NEWEST row
/// (the list is reversed, so index 0 draws at the bottom).
sealed class ThreadItem {
  const ThreadItem();

  /// Stable key of the row (message id, or the day for a separator).
  String get key;
}

/// A message bubble and where it sits in its group.
class MessageItem extends ThreadItem {
  const MessageItem(
    this.message, {
    required this.firstOfGroup,
    required this.lastOfGroup,
  });

  final pb.Message message;

  /// The oldest bubble of its group (the top one): the group's gap above it.
  final bool firstOfGroup;

  /// The newest bubble of its group (the bottom one): shows the time under it.
  final bool lastOfGroup;

  @override
  String get key => 'message-${message.id}';
}

/// "Today", "Yesterday" or a date, between two days.
class DaySeparatorItem extends ThreadItem {
  const DaySeparatorItem(this.day);

  /// Local midnight of the day.
  final DateTime day;

  @override
  String get key => 'day-${day.year}-${day.month}-${day.day}';
}

DateTime? _createdAt(pb.Message m) =>
    m.hasCreatedAt() ? m.createdAt.toDateTime().toLocal() : null;

DateTime _dayOf(DateTime local) => DateTime(local.year, local.month, local.day);

/// Turns [newestFirst] messages (as the repository returns them) into list
/// rows, newest first: grouped by sender (`from_self`) within one local day,
/// with a day separator above the first message of each day. Pure, so it is
/// unit-tested without a widget.
///
/// A message without a time (a malformed row) joins the group of the message
/// before it and starts no day.
List<ThreadItem> buildThreadItems(List<pb.Message> newestFirst) {
  final chronological = newestFirst.reversed.toList(growable: false);
  final rows = <ThreadItem>[];
  DateTime? lastDay;
  for (var i = 0; i < chronological.length; i++) {
    final message = chronological[i];
    final at = _createdAt(message);
    final day = at == null ? lastDay : _dayOf(at);
    final newDay = day != null && day != lastDay;
    if (newDay) rows.add(DaySeparatorItem(day));
    lastDay = day ?? lastDay;

    final previous = i == 0 ? null : chronological[i - 1];
    final next = i == chronological.length - 1 ? null : chronological[i + 1];
    final firstOfGroup =
        previous == null || newDay || previous.fromSelf != message.fromSelf;
    final nextAt = next == null ? null : _createdAt(next);
    final nextStartsDay =
        nextAt != null && day != null && _dayOf(nextAt) != day;
    final lastOfGroup =
        next == null || nextStartsDay || next.fromSelf != message.fromSelf;
    rows.add(
      MessageItem(
        message,
        firstOfGroup: firstOfGroup,
        lastOfGroup: lastOfGroup,
      ),
    );
  }
  return rows.reversed.toList(growable: false);
}

/// The label of a day separator: `Today`, `Yesterday`, the weekday and date
/// within the current year (`Sun, Oct 25`), else with the year. [now] is
/// injected.
String formatDaySeparator(DateTime day, DateTime now) {
  final today = _dayOf(now.toLocal());
  // Calendar days, so a daylight-saving change cannot make 23 hours of
  // "yesterday" read as today.
  final diff = DateTime.utc(
    today.year,
    today.month,
    today.day,
  ).difference(DateTime.utc(day.year, day.month, day.day)).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  return day.year == today.year
      ? DateFormat.MMMEd().format(day)
      : formatScheduledDate(day);
}
