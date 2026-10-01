import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/posts/domain/posts_feature_flag.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/posts_fixtures.dart';

void main() {
  Future<void> disableAll(PostsFeatureGate gate) async {
    try {
      await gate.run<void>(
        () async => throw serverError(
          connect.Code.failedPrecondition,
          common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        ),
      );
    } on FeatureDisabledException {
      // expected
    }
  }

  test('refresh is requested once for concurrent disables, and at most once '
      'per 60 s', () async {
    var now = DateTime(2026, 1, 1);
    var refreshes = 0;
    final gate = PostsFeatureGate(
      isPostsEnabled: () => true,
      onWholeServiceDisabled: () => refreshes++,
      now: () => now,
    );

    await Future.wait([disableAll(gate), disableAll(gate), disableAll(gate)]);
    expect(refreshes, 1, reason: 'state changed once');

    // A successful GetMe resets; a new disable inside 60 s is rate limited.
    gate.reset();
    now = now.add(const Duration(seconds: 30));
    await disableAll(gate);
    expect(refreshes, 1);
    expect(gate.postsEnabled, isFalse, reason: 'fail-closed');

    gate.reset();
    now = now.add(const Duration(seconds: 31));
    await disableAll(gate);
    expect(refreshes, 2);
  });
}
