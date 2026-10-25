import 'package:dzeroth/shared/format/scheduled_time.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 9:37 PM on a mid-year Sunday-independent local date.
  final evening = DateTime(DateTime.now().year, 6, 15, 21, 37);
  final morning = DateTime(DateTime.now().year, 6, 15, 9, 5);

  test('12-hour clock: "9:37 PM" (the space may be a narrow no-break one)', () {
    final clock = formatScheduledClock(evening);
    expect(clock.replaceAll(RegExp(r'\s'), ' '), '9:37 PM');
    expect(
      formatScheduledClock(morning).replaceAll(RegExp(r'\s'), ' '),
      '9:05 AM',
    );
  });

  test('24-hour clock', () {
    expect(formatScheduledClock(evening, use24Hour: true), '21:37');
    expect(formatScheduledClock(morning, use24Hour: true), '09:05');
  });

  test('the date has the weekday, month, day and year', () {
    final date = formatScheduledDate(evening);
    expect(date, matches(RegExp(r'^[A-Z][a-z]{2}, Jun 15, \d{4}$')));
  });

  test('the full text joins them with " at "', () {
    final text = formatScheduledTime(evening);
    expect(text, startsWith(formatScheduledDate(evening)));
    expect(text, contains(' at '));
    expect(text.replaceAll(RegExp(r'\s'), ' '), endsWith('9:37 PM'));
  });

  test('a UTC instant is shown in the device zone', () {
    expect(formatScheduledTime(evening.toUtc()), formatScheduledTime(evening));
  });

  test('willSendOnText prefixes the sentence', () {
    expect(
      willSendOnText(evening),
      'Will send on ${formatScheduledTime(evening)}',
    );
    expect(willSendOnText(evening, use24Hour: true), endsWith('at 21:37'));
  });

  test('the zone label names the zone and its offset', () {
    final label = scheduleZoneLabel(evening);
    expect(label, startsWith('Time zone: '));
    expect(label, matches(RegExp(r'\(UTC[+-]\d{2}:\d{2}\)$')));
  });
}
