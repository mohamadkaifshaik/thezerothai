import 'dart:async';

import 'package:dzeroth/core/storage/session_epoch.dart';
import 'package:dzeroth/features/premium/data/server_subscription_repository.dart';
import 'package:dzeroth/features/premium/data/subscription_sources.dart';
import 'package:dzeroth/features/premium/domain/subscription_models.dart';
import 'package:flutter_test/flutter_test.dart';

const _offer = SubscriptionOffering(
  packageIdentifier: 'monthly',
  productIdentifier: 'plus',
  tier: SubscriptionTier.plus,
  localizedPrice: 'store price',
  billingPeriod: 'monthly',
);

class _Source implements SubscriptionStatusSource {
  String uid = 'a';
  bool sales = true;
  String identity = 'dzb_${'A' * 43}';
  Completer<String>? delayedIdentity;

  @override
  Future<SubscriptionAccess> getAccess() async => SubscriptionAccess(
    uid: uid,
    tier: SubscriptionTier.free,
    verification: SubscriptionVerification.noSubscription,
    purchasesAvailable: sales,
  );

  @override
  Future<String> ensureBillingIdentity() async =>
      delayedIdentity == null ? identity : await delayedIdentity!.future;
}

class _Gateway
    implements SubscriptionPurchaseGateway, SubscriptionHostedUiGateway {
  final calls = <String>[];
  Completer<SubscriptionPurchaseResult>? delayedPurchase;
  Object? purchaseError;

  @override
  Future<SubscriptionPurchaseResult> presentPaywall() async {
    calls.add('paywall');
    if (purchaseError != null) throw purchaseError!;
    return const SubscriptionPurchaseResult(PurchaseDisposition.verifying);
  }

  @override
  Future<void> presentCustomerCenter() async {
    calls.add('manage');
  }

  @override
  Future<void> identify(String id) async => calls.add('identify');

  @override
  Future<List<SubscriptionOffering>> getOfferings() async {
    calls.add('offerings');
    return [_offer];
  }

  @override
  Future<SubscriptionPurchaseResult> purchase(SubscriptionOffering o) async {
    calls.add('purchase');
    if (purchaseError != null) throw purchaseError!;
    return delayedPurchase == null
        ? const SubscriptionPurchaseResult(PurchaseDisposition.verifying)
        : await delayedPurchase!.future;
  }

  @override
  Future<SubscriptionPurchaseResult> restore() async {
    calls.add('restore');
    return const SubscriptionPurchaseResult(PurchaseDisposition.verifying);
  }
}

void main() {
  late _Source source;
  late _Gateway gateway;
  late SessionEpoch epoch;
  late ServerSubscriptionRepository repository;
  String? currentUid;

  setUp(() {
    source = _Source();
    gateway = _Gateway();
    epoch = SessionEpoch();
    currentUid = 'a';
    repository = ServerSubscriptionRepository(
      source: source,
      gateway: gateway,
      sessionEpoch: epoch,
      currentUid: () => currentUid,
    );
  });

  test('sales disabled blocks offers but permits identified restore', () async {
    source.sales = false;
    expect(await repository.getOfferings('a'), isEmpty);
    expect(gateway.calls, isEmpty);
    await repository.restore('a');
    expect(gateway.calls, ['identify', 'restore']);
  });

  test(
    'hosted checkout requires server sales and blocks repeat checkout',
    () async {
      source.sales = false;
      await expectLater(repository.presentPaywall('a'), throwsStateError);
      expect(gateway.calls, isEmpty);
      source.sales = true;
      final result = await repository.presentPaywall('a');
      expect(result.disposition, PurchaseDisposition.verifying);
      await expectLater(repository.presentPaywall('a'), throwsStateError);
      expect(gateway.calls, ['identify', 'paywall']);
    },
  );

  test('management remains available with sales disabled', () async {
    source.sales = false;
    await repository.presentCustomerCenter('a');
    expect(gateway.calls, ['identify', 'manage']);
  });

  test('ambiguous hosted checkout failure retains purchase guard', () async {
    gateway.purchaseError = StateError('timeout');
    await expectLater(repository.presentPaywall('a'), throwsStateError);
    gateway.purchaseError = null;
    await expectLater(repository.presentPaywall('a'), throwsStateError);
    expect(gateway.calls, ['identify', 'paywall']);
  });

  test(
    'purchase rechecks server availability after offers were loaded',
    () async {
      await repository.getOfferings('a');
      source.sales = false;
      await expectLater(repository.purchase('a', _offer), throwsStateError);
      expect(gateway.calls, ['identify', 'offerings']);
    },
  );

  test('SDK success does not grant access or permit a duplicate', () async {
    await repository.getOfferings('a');
    await repository.purchase('a', _offer);
    expect((await repository.getAccess('a')).tier, SubscriptionTier.free);
    expect(await repository.getOfferings('a'), isEmpty);
    await expectLater(repository.purchase('a', _offer), throwsStateError);
    expect(gateway.calls.where((c) => c == 'purchase').length, 1);
  });

  test('ambiguous SDK error blocks another checkout', () async {
    await repository.getOfferings('a');
    gateway.purchaseError = StateError('timeout');
    await expectLater(repository.purchase('a', _offer), throwsStateError);
    expect(await repository.getOfferings('a'), isEmpty);
  });

  test('wrong owner and public UID cannot reach SDK', () async {
    source.uid = 'b';
    await expectLater(repository.getOfferings('a'), throwsStateError);
    source.uid = 'a';
    source.identity = 'a';
    await expectLater(repository.restore('a'), throwsStateError);
    expect(gateway.calls, isEmpty);
  });

  test('epoch change during identity read prevents SDK operation', () async {
    source.delayedIdentity = Completer<String>();
    final restore = repository.restore('a');
    final rejected = expectLater(restore, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    epoch.end();
    source.delayedIdentity!.complete(source.identity);
    await rejected;
    expect(gateway.calls, isEmpty);
  });

  test(
    'account switch waits for old purchase before SDK identification',
    () async {
      await repository.getOfferings('a');
      gateway.delayedPurchase = Completer<SubscriptionPurchaseResult>();
      final purchase = repository.purchase('a', _offer);
      final rejected = expectLater(purchase, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      expect(gateway.calls.last, 'purchase');
      currentUid = 'b';
      source.uid = 'b';
      epoch.end();
      repository.clearSession();
      final restore = repository.restore('b');
      await Future<void>.delayed(Duration.zero);
      expect(gateway.calls.last, 'purchase');
      gateway.delayedPurchase!.complete(
        const SubscriptionPurchaseResult(PurchaseDisposition.verifying),
      );
      await rejected;
      await restore;
      expect(gateway.calls.sublist(gateway.calls.length - 2), [
        'identify',
        'restore',
      ]);
    },
  );
}
