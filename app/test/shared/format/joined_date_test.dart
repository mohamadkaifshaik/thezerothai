import 'package:dzeroth/shared/format/joined_date.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as pb;

void main() {
  setUpAll(() => initializeDateFormatting('es'));

  // Mid-month noon UTC: the same month in every time zone.
  final march = DateTime.utc(2026, 3, 15, 12);

  test('formatJoinedMonth: full month name and year', () {
    expect(formatJoinedMonth(march), 'March 2026');
  });

  test('formatJoinedMonth: follows the intl locale', () {
    Intl.withLocale('es', () {
      expect(formatJoinedMonth(march), 'marzo de 2026');
    });
  });

  test('joinedText: "Joined" + the month of the created time', () {
    expect(joinedText(pb.Timestamp.fromDateTime(march)), 'Joined March 2026');
  });

  test('joinedText: an unset or zero timestamp gives no text', () {
    expect(joinedText(null), isNull);
    expect(joinedText(pb.Timestamp()), isNull);
    // Go's zero time.Time as the server would send it (year 1).
    expect(joinedText(pb.Timestamp(seconds: Int64(-62135596800))), isNull);
  });
}
