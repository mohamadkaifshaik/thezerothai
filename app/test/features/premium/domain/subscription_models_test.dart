import 'package:dzeroth/features/premium/domain/subscription_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.now().toUtc();

  test('paid access expires at the earlier access/freshness boundary', () {
    SubscriptionAccess access(DateTime checked, DateTime until) =>
        SubscriptionAccess(
          uid: 'a',
          tier: SubscriptionTier.premium,
          verification: SubscriptionVerification.verified,
          verifiedAt: checked,
          validUntil: until,
        );
    expect(
      access(now, now.add(const Duration(minutes: 1))).effectiveTier(now),
      SubscriptionTier.premium,
    );
    expect(access(now, now).effectiveTier(now), isNull);
    expect(
      access(
        now.subtract(const Duration(minutes: 15)),
        now.add(const Duration(hours: 1)),
      ).effectiveTier(now),
      isNull,
    );
    expect(
      access(
        now.add(const Duration(seconds: 1)),
        now.add(const Duration(hours: 1)),
      ).effectiveTier(now),
      isNull,
    );
  });

  test('no-subscription response cannot assert a paid or unknown tier', () {
    for (final tier in SubscriptionTier.values) {
      final access = SubscriptionAccess(
        uid: 'a',
        tier: tier,
        verification: SubscriptionVerification.noSubscription,
      );
      expect(
        access.effectiveTier(now),
        tier == SubscriptionTier.free ? SubscriptionTier.free : null,
      );
    }
  });
}
