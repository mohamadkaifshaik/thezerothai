import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/moderation/presentation/report_error_messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String message(AppException e) => reportErrorMessage(e);

  test('a validation error is worded by the field the server names', () {
    expect(
      message(const ValidationException('x', field: 'note')),
      contains("details can't be sent"),
    );
    expect(
      message(const ValidationException('x', field: 'reason')),
      contains('Choose a reason'),
    );
    expect(
      message(const ValidationException('x', field: 'target_id')),
      contains('your own content'),
    );
  });

  test('an unknown or missing field never claims "your own content"', () {
    expect(
      message(const ValidationException('x', field: 'idempotency_key')),
      isNot(contains('own content')),
    );
    expect(
      message(const ValidationException('x')),
      isNot(contains('own content')),
    );
  });

  test('server text is never shown', () {
    expect(
      message(const UnknownApiException('secret internals')),
      isNot(contains('secret')),
    );
  });
}
