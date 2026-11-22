import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/network/rate_limit_hold.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('overlapping responses retain the longest outstanding deadline', () {
    var elapsed = Duration.zero;
    final hold = RateLimitHold(monotonic: () => elapsed);
    hold.record(
      const RateLimitedException('first', retryAfter: Duration(minutes: 5)),
    );
    elapsed = const Duration(minutes: 1);
    hold.record(
      const RateLimitedException('second', retryAfter: Duration(seconds: 30)),
    );
    expect(hold.check()?.message, 'first');
    expect(hold.check()?.retryAfter, const Duration(minutes: 4));
    hold.record(
      const RateLimitedException('third', retryAfter: Duration(minutes: 5)),
    );
    elapsed = const Duration(minutes: 5);
    expect(hold.check()?.message, 'third');
    expect(hold.check()?.retryAfter, const Duration(minutes: 1));
    elapsed = const Duration(minutes: 6);
    expect(hold.check(), isNull);
  });
}
