import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/posts/presentation/post_error_messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('maps each CreatePost failure to friendly, typed text', () {
    expect(
      createPostErrorMessage(const QuotaExceededException('x')),
      contains("today's limit"),
    );
    expect(
      createPostErrorMessage(const RateLimitedException('x')),
      contains('too fast'),
    );
    expect(
      createPostErrorMessage(const EmailNotVerifiedException('x')),
      contains('verify your email'),
    );
    expect(
      createPostErrorMessage(const DegradedModeException('x')),
      contains('limited mode'),
    );
    expect(
      createPostErrorMessage(const FeatureDisabledException('x')),
      contains("isn't available"),
    );
    expect(
      createPostErrorMessage(const NetworkException('x')),
      contains('No connection'),
    );
  });

  test('replyErrorMessage uses reply wording and falls back to the shared '
      'messages', () {
    expect(
      replyErrorMessage(const NotFoundException('x')),
      contains("isn't available any more"),
    );
    expect(
      replyErrorMessage(const FeatureDisabledException('x')),
      contains("Replies aren't available"),
    );
    expect(
      replyErrorMessage(const NetworkException('x')),
      contains('Your reply was not sent'),
    );
    expect(
      replyErrorMessage(const QuotaExceededException('x')),
      contains("today's limit"),
    );
    expect(
      replyErrorMessage(const UnknownApiException('stack trace here')),
      allOf(contains('reply'), isNot(contains('stack trace'))),
    );
  });

  test('never leaks the raw server message', () {
    expect(
      createPostErrorMessage(const UnknownApiException('stack trace here')),
      isNot(contains('stack trace')),
    );
  });
}
