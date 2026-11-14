import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/shared/format/rate_limited_message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a transient limit asks for a moment, a daily one says it resets', () {
    expect(
      rateLimitedMessage(const RateLimitedException('x')),
      "You're doing that a bit too fast. Give it a moment and try again.",
    );
    expect(
      rateLimitedMessage(
        const RateLimitedException('x', retryAfter: Duration(hours: 3)),
      ),
      "You've reached today's limit for this. It resets in about 3 hours.",
    );
  });
}
