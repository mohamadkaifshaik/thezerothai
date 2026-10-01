import 'package:dzeroth/shared/format/relative_time.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 5, 20, 12);

  test('compact form', () {
    expect(formatRelativeTime(now, now), 'now');
    expect(formatRelativeTime(now.add(const Duration(hours: 1)), now), 'now');
    expect(
      formatRelativeTime(now.subtract(const Duration(minutes: 5)), now),
      '5m',
    );
    expect(
      formatRelativeTime(now.subtract(const Duration(hours: 3)), now),
      '3h',
    );
    expect(
      formatRelativeTime(now.subtract(const Duration(days: 2)), now),
      '2d',
    );
    expect(formatRelativeTime(DateTime(2026, 3, 4), now), 'Mar 4');
    expect(formatRelativeTime(DateTime(2025, 3, 4), now), 'Mar 4, 2025');
  });

  test('spoken form', () {
    expect(formatRelativeTimeSpoken(now, now), 'just now');
    expect(
      formatRelativeTimeSpoken(now.subtract(const Duration(minutes: 1)), now),
      '1 minute ago',
    );
    expect(
      formatRelativeTimeSpoken(now.subtract(const Duration(hours: 3)), now),
      '3 hours ago',
    );
    expect(
      formatRelativeTimeSpoken(now.subtract(const Duration(days: 2)), now),
      '2 days ago',
    );
    expect(
      formatRelativeTimeSpoken(DateTime(2026, 3, 4), now),
      'March 4, 2026',
    );
  });
}
