import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dzeroth/features/premium/data/revenuecat_purchase_gateway.dart';
import 'package:dzeroth/features/premium/domain/subscription_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('purchases_flutter');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('rejects public identities before contacting the SDK', () async {
    final gateway = RevenueCatPurchaseGateway(
      publicApiKey: 'test-public-key',
      monthlyProducts: const {},
    );
    await expectLater(gateway.identify('public-user'), throwsStateError);
    await expectLater(gateway.restore(), throwsStateError);
    expect(calls, isEmpty);
  });

  test(
    'configures with private identity and never creates anonymous customer',
    () async {
      final gateway = RevenueCatPurchaseGateway(
        publicApiKey: 'test-public-key',
        monthlyProducts: const {},
      );
      final id = 'dzb_${'A' * 43}';
      await gateway.identify(id);
      await gateway.identify(id);
      expect(calls.map((c) => c.method), ['setupPurchases']);
      expect((calls.single.arguments as Map)['appUserId'], id);
      final invented = SubscriptionOffering(
        packageIdentifier: 'invented',
        productIdentifier: 'invented',
        tier: SubscriptionTier.premium,
        localizedPrice: '1',
        billingPeriod: 'monthly',
      );
      await expectLater(gateway.purchase(invented), throwsStateError);
      expect(calls, hasLength(1));
    },
  );
}
