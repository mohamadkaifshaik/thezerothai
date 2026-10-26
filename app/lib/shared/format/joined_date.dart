import 'package:fixnum/fixnum.dart';
import 'package:intl/intl.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as pb;

/// The month and year of [time] in the device zone and the app's default intl
/// locale, for example `October 2026`. [time] may be UTC (the wire value),
/// like the other date formatters.
String formatJoinedMonth(DateTime time) =>
    DateFormat.yMMMM().format(time.toLocal());

/// `Joined October 2026`: the profile meta row. Null when [createdAt] is
/// unset (an unset protobuf timestamp reads as 1970) or not after the epoch
/// (the server sends year 1 for a profile document without a `createdAt`):
/// none of those may be shown, so the row is simply left out.
String? joinedText(pb.Timestamp? createdAt) {
  if (createdAt == null || createdAt.seconds <= Int64.ZERO) return null;
  return 'Joined ${formatJoinedMonth(createdAt.toDateTime())}';
}
