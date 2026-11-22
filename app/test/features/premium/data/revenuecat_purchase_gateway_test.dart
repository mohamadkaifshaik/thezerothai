import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dzeroth/features/premium/data/revenuecat_purchase_gateway.dart';
import 'package:dzeroth/features/premium/domain/subscription_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('purchases_flutter');
  final calls = <MethodCall>[];
  Map<String, Object?>? nativeOfferings;

  setUp(() {
    calls.clear();
    nativeOfferings = null;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'getOfferings') return nativeOfferings;
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
    'custom monthly packages use the configured Play base-plan mapping',
    () async {
      final packages = [
        for (final product in ['plus:monthly', 'old:monthly', 'plus:yearly'])
          {
            'identifier': product,
            'packageType': 'CUSTOM',
            'presentedOfferingContext': {'offeringIdentifier': 'default'},
            'product': {
              'identifier': product,
              'description': 'fixture description',
              'title': 'fixture title',
              'price': product == 'old:monthly' ? 235.0 : 99.0,
              'priceString': 'fixture store price',
              'currencyCode': 'INR',
              'subscriptionPeriod': product.endsWith('monthly') ? 'P1M' : 'P1Y',
            },
          },
      ];
      final offering = {
        'identifier': 'default',
        'serverDescription': 'fixture offering',
        'metadata': <String, Object>{},
        'availablePackages': packages,
      };
      nativeOfferings = {
        'all': {'default': offering},
        'current': offering,
      };
      final gateway = RevenueCatPurchaseGateway(
        publicApiKey: 'fixture-public-key',
        monthlyProducts: const {
          'plus:monthly': SubscriptionTier.plus,
          'old:monthly': SubscriptionTier.plus,
          'plus:yearly': SubscriptionTier.plus,
        },
      );
      await gateway.identify('dzb_${'A' * 43}');
      final offers = await gateway.getOfferings();
      expect(offers.map((o) => o.productIdentifier), ['plus:monthly']);
      expect(offers.single.localizedPrice, 'fixture store price');
      expect(offers.single.tier, SubscriptionTier.plus);
    },
  );

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
        tier: SubscriptionTier.plus,
        localizedPrice: '1',
        billingPeriod: 'monthly',
      );
      await expectLater(gateway.purchase(invented), throwsStateError);
      expect(calls, hasLength(1));
    },
  );
}
