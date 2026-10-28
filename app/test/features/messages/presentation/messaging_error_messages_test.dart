import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/network/connect_error_mapper.dart';
import 'package:dzeroth/features/messages/presentation/messaging_error_messages.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/messaging_fixtures.dart';

AppException mapped(
  connect.Code code,
  common.ErrorReason reason, [
  Map<String, String> metadata = const {},
]) => mapConnectError(withDetail(code, reason, metadata: metadata));

void main() {
  test('CANNOT_MESSAGE maps to the typed exception with the fixed text', () {
    final e = mapped(
      connect.Code.failedPrecondition,
      common.ErrorReason.ERROR_REASON_CANNOT_MESSAGE,
    );
    expect(e, isA<CannotMessageException>());
    expect(messagingErrorMessage(e), "You can't message this account.");
    // Never the server's text.
    expect(messagingErrorMessage(e), isNot(contains('server text')));
  });

  test('LIMIT_REACHED names request_unanswered and dm_new_daily apart', () {
    final unanswered = mapped(
      connect.Code.failedPrecondition,
      common.ErrorReason.ERROR_REASON_LIMIT_REACHED,
      {'limit': 'request_unanswered'},
    );
    final daily = mapped(
      connect.Code.failedPrecondition,
      common.ErrorReason.ERROR_REASON_LIMIT_REACHED,
      {'limit': 'dm_new_daily'},
    );
    expect((unanswered as LimitReachedException).quota, 'request_unanswered');
    expect((daily as LimitReachedException).quota, 'dm_new_daily');
    final a = messagingErrorMessage(unanswered);
    final b = messagingErrorMessage(daily);
    expect(a, contains('accept your request'));
    expect(b, contains('new conversations'));
    expect(a, isNot(b));
    expect(
      messagingErrorMessage(const LimitReachedException('x', quota: 'other')),
      "You've reached the limit for messaging.",
    );
    expect(a + b, isNot(contains('server text')));
  });

  test('RATE_LIMITED: a daily cap says it resets, a short one says wait', () {
    final daily = mapped(
      connect.Code.resourceExhausted,
      common.ErrorReason.ERROR_REASON_RATE_LIMITED,
      {'limit': 'messages_daily'},
    );
    final burst = mapped(
      connect.Code.resourceExhausted,
      common.ErrorReason.ERROR_REASON_RATE_LIMITED,
      {'limit': 'messages_send_per_min'},
    );
    expect(messagingErrorMessage(daily), contains("today's limit"));
    expect(messagingErrorMessage(burst), contains('a bit too fast'));
  });

  test(
    'FEATURE_DISABLED, degraded mode, offline and the rest are friendly',
    () {
      expect(
        messagingErrorMessage(
          mapped(
            connect.Code.failedPrecondition,
            common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
            {'feature': 'messaging'},
          ),
        ),
        "Messages aren't available right now.",
      );
      final degraded = messagingErrorMessage(
        mapped(
          connect.Code.unavailable,
          common.ErrorReason.ERROR_REASON_DEGRADED_MODE,
        ),
      );
      expect(degraded, contains('limited mode'));
      expect(degraded, isNot(contains('server text')));
      expect(
        messagingErrorMessage(const NetworkException('x')),
        startsWith('No connection'),
      );
      expect(
        messagingErrorMessage(const NotFoundException('x')),
        "This conversation isn't available anymore.",
      );
      expect(
        messagingErrorMessage(const UnknownApiException('secret')),
        isNot(contains('secret')),
      );
    },
  );
}
