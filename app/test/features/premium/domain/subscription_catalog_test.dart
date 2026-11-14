import 'package:dzeroth/features/premium/domain/subscription_catalog.dart';
import 'package:dzeroth/features/premium/domain/subscription_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('maps reviewed Google subscription/base-plan identifiers', () {
    final products = parseMonthlySubscriptionProducts(
      '{"plus:monthly":"plus","premium:monthly":"premium"}',
    );
    expect(products, {
      'plus:monthly': SubscriptionTier.plus,
      'premium:monthly': SubscriptionTier.premium,
    });
    expect(() => products.clear(), throwsUnsupportedError);
  });

  test(
    'invalid build configuration cannot offer a partial checkout catalog',
    () {
      for (final raw in [
        '',
        '{',
        '[]',
        '{}',
        '{"monthly":"free"}',
        '{"monthly":"premium","other":"unknown"}',
        '{"":"premium"}',
        '{"premium monthly":"premium"}',
        '{"monthly":{}}',
      ]) {
        expect(parseMonthlySubscriptionProducts(raw), isEmpty, reason: raw);
      }
    },
  );
}
