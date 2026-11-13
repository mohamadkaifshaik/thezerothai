import 'dart:async';

import 'package:dzeroth/core/storage/session_epoch.dart';
import 'package:dzeroth/features/premium/domain/subscription_models.dart';
import 'package:dzeroth/features/premium/domain/subscription_repository.dart';
import 'package:dzeroth/features/premium/presentation/bloc/subscription_cubit.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime.now().toUtc();
const _offering = SubscriptionOffering(
  packageIdentifier: 'plus-monthly',
  productIdentifier: 'test-plus',
  tier: SubscriptionTier.plus,
  localizedPrice: 'localized-store-price',
  billingPeriod: 'monthly',
);

SubscriptionAccess _free(String uid, {bool sales = false}) =>
    SubscriptionAccess(
      uid: uid,
      tier: SubscriptionTier.free,
      verification: SubscriptionVerification.noSubscription,
      purchasesAvailable: sales,
    );

class _Repository
    implements SubscriptionRepository, HostedSubscriptionRepository {
  Future<SubscriptionAccess> Function(String) access = (uid) async =>
      _free(uid);
  Future<SubscriptionPurchaseResult> Function() transaction = () async =>
      const SubscriptionPurchaseResult(PurchaseDisposition.verifying);
  int resets = 0;
  int offeringLoads = 0;
  int purchases = 0;
  int restores = 0;
  int paywalls = 0;
  int manages = 0;

  @override
  Future<SubscriptionPurchaseResult> presentPaywall(String uid) {
    paywalls++;
    return transaction();
  }

  @override
  Future<void> presentCustomerCenter(String uid) async {
    manages++;
  }

  @override
  void clearSession() => resets++;

  @override
  Future<SubscriptionAccess> getAccess(String uid) => access(uid);

  @override
  Future<List<SubscriptionOffering>> getOfferings(String uid) async {
    offeringLoads++;
    return [_offering];
  }

  @override
  Future<SubscriptionPurchaseResult> purchase(
    String uid,
    SubscriptionOffering offering,
  ) {
    purchases++;
    return transaction();
  }

  @override
  Future<SubscriptionPurchaseResult> restore(String uid) {
    restores++;
    return transaction();
  }
}

void main() {
  late _Repository repo;
  late SessionEpoch epoch;
  late SubscriptionCubit cubit;

  setUp(() {
    repo = _Repository();
    epoch = SessionEpoch();
    cubit = SubscriptionCubit(
      repository: repo,
      sessionEpoch: epoch,
      now: () => _now,
    );
  });

  tearDown(() async {
    await cubit.close();
  });

  test('dark status does not load offerings or start a purchase', () async {
    await cubit.setAccount('a');
    expect(cubit.state.phase, SubscriptionPhase.ready);
    expect(repo.offeringLoads, 0);
    await cubit.purchase(_offering);
    expect(repo.purchases, 0);
    await cubit.showPaywall();
    expect(repo.paywalls, 0);
  });

  test(
    'hosted paywall waits for server verification and cannot reopen',
    () async {
      repo.access = (uid) async => _free(uid, sales: true);
      await cubit.setAccount('a');
      await cubit.showPaywall();
      expect(repo.paywalls, 1);
      expect(cubit.state.phase, SubscriptionPhase.verifying);
      await cubit.showPaywall();
      expect(repo.paywalls, 1);
    },
  );

  test('management remains reachable without new sales', () async {
    await cubit.setAccount('a');
    await cubit.manageSubscription();
    expect(repo.manages, 1);
    expect(cubit.state.phase, SubscriptionPhase.verifying);
  });

  test('wrong owner and unavailable access cannot enter ready state', () async {
    repo.access = (_) async => _free('b', sales: true);
    await cubit.setAccount('a');
    expect(cubit.state.phase, SubscriptionPhase.unavailable);
    expect(cubit.state.access, isNull);
    expect(repo.offeringLoads, 0);
  });

  test('late account A status cannot replace account B', () async {
    final delayed = Completer<SubscriptionAccess>();
    repo.access = (uid) =>
        uid == 'a' ? delayed.future : Future.value(_free(uid));
    final first = cubit.setAccount('a');
    await cubit.setAccount('b');
    delayed.complete(_free('a', sales: true));
    await first;
    expect(cubit.state.uid, 'b');
    expect(cubit.state.access?.uid, 'b');
    expect(repo.offeringLoads, 0);
  });

  test('shared session epoch rejects late status writes', () async {
    final delayed = Completer<SubscriptionAccess>();
    repo.access = (_) => delayed.future;
    final loading = cubit.setAccount('a');
    epoch.end();
    delayed.complete(_free('a', sales: true));
    await loading;
    expect(cubit.state.access, isNull);
    expect(repo.offeringLoads, 0);
    await cubit.setAccount(null);
    expect(cubit.state.phase, SubscriptionPhase.signedOut);
  });

  test('store success with delayed server access remains verifying', () async {
    repo.access = (uid) async => _free(uid, sales: true);
    await cubit.setAccount('a');
    await cubit.purchase(_offering);
    expect(cubit.state.phase, SubscriptionPhase.verifying);
    expect(cubit.state.access?.tier, SubscriptionTier.free);
    expect(cubit.state.offerings, isEmpty);
    await cubit.purchase(_offering);
    expect(repo.purchases, 1);
    repo.access = (uid) async => SubscriptionAccess(
      uid: uid,
      tier: SubscriptionTier.plus,
      verification: SubscriptionVerification.verified,
      verifiedAt: _now,
      validUntil: _now.add(const Duration(minutes: 10)),
      purchasesAvailable: true,
    );
    await cubit.refresh();
    expect(cubit.state.phase, SubscriptionPhase.ready);
    expect(cubit.state.access?.tier, SubscriptionTier.plus);
    // Existing subscribers must not accidentally buy a second store plan.
    await cubit.purchase(_offering);
    expect(repo.purchases, 1);
  });

  test('canceled purchase reloads without leaving a purchase lock', () async {
    repo.access = (uid) async => _free(uid, sales: true);
    repo.transaction = () async =>
        const SubscriptionPurchaseResult(PurchaseDisposition.canceled);
    await cubit.setAccount('a');
    await cubit.purchase(_offering);
    expect(cubit.state.phase, SubscriptionPhase.ready);
    expect(cubit.state.offerings, [_offering]);
  });

  test('pending purchase blocks duplicate submission after refresh', () async {
    repo.access = (uid) async => _free(uid, sales: true);
    repo.transaction = () async =>
        const SubscriptionPurchaseResult(PurchaseDisposition.pending);
    await cubit.setAccount('a');
    await cubit.purchase(_offering);
    await cubit.refresh();
    expect(cubit.state.phase, SubscriptionPhase.pending);
    await cubit.purchase(_offering);
    expect(repo.purchases, 1);
  });

  test('purchase completion after account switch cannot affect B', () async {
    repo.access = (uid) async => _free(uid, sales: true);
    final delayed = Completer<SubscriptionPurchaseResult>();
    repo.transaction = () => delayed.future;
    await cubit.setAccount('a');
    final purchase = cubit.purchase(_offering);
    await cubit.setAccount('b');
    delayed.complete(
      const SubscriptionPurchaseResult(PurchaseDisposition.verifying),
    );
    await purchase;
    expect(cubit.state.uid, 'b');
    expect(cubit.state.phase, SubscriptionPhase.ready);
    expect(cubit.state.access?.uid, 'b');
  });

  test('restore remains available when new sales are off', () async {
    await cubit.setAccount('a');
    await cubit.restore();
    expect(repo.restores, 1);
    expect(cubit.state.phase, SubscriptionPhase.verifying);
  });

  test(
    'unknown status is an unavailable state, not a confirmed free tier',
    () async {
      repo.access = (uid) async => SubscriptionAccess(
        uid: uid,
        tier: SubscriptionTier.free,
        verification: SubscriptionVerification.unavailable,
      );
      await cubit.setAccount('a');
      expect(cubit.state.phase, SubscriptionPhase.unavailable);
      expect(cubit.state.access, isNull);
    },
  );

  test(
    'repository failure is retryable without exposing provider errors',
    () async {
      repo.access = (_) async => throw StateError('private provider detail');
      await cubit.setAccount('a');
      expect(cubit.state.phase, SubscriptionPhase.unavailable);
      expect(cubit.state.offerings, isEmpty);
      repo.access = (uid) async => _free(uid);
      await cubit.refresh();
      expect(cubit.state.phase, SubscriptionPhase.ready);
    },
  );
}
