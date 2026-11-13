import 'subscription_models.dart';

/// Premium's single integration seam. The implementation combines a protected
/// Connect status source with a platform purchase gateway; it must never use
/// client purchase results as authorization. Authentication/account switching
/// and provider SDK identification must complete before any purchase.
abstract interface class SubscriptionRepository {
  Future<SubscriptionAccess> getAccess(String uid);

  Future<List<SubscriptionOffering>> getOfferings(String uid);

  Future<SubscriptionPurchaseResult> purchase(
    String uid,
    SubscriptionOffering offering,
  );

  /// Mobile restore verifies store ownership. Web implementations recover the
  /// signed-in customer's status; native restorePurchases is unsupported there.
  Future<SubscriptionPurchaseResult> restore(String uid);

  /// Invalidates per-account memory immediately, including late SDK callbacks.
  /// Gateway operations must remain serialized even across an account switch.
  /// Register with AccountSessionReset when the concrete adapter is wired.
  void clearSession();
}

abstract interface class HostedSubscriptionRepository {
  Future<SubscriptionPurchaseResult> presentPaywall(String uid);
  Future<void> presentCustomerCenter(String uid);
}
