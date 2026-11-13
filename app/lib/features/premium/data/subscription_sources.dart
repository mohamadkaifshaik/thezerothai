import '../domain/subscription_models.dart';

/// Protected owner RPCs. Implementations use the current authenticated caller;
/// there is deliberately no UID or provider-ID parameter on these methods.
abstract interface class SubscriptionStatusSource {
  Future<SubscriptionAccess> getAccess();
  Future<String> ensureBillingIdentity();
}

/// The SDK adapter owns platform configuration and package handles. It must not
/// create anonymous customers or turn SDK entitlements into server access.
/// One instance must be shared with one repository for the application lifetime.
abstract interface class SubscriptionPurchaseGateway {
  Future<void> identify(String privateCustomerId);
  Future<List<SubscriptionOffering>> getOfferings();
  Future<SubscriptionPurchaseResult> purchase(SubscriptionOffering offering);

  /// Native store restore on mobile; customer refresh on web, where native
  /// restorePurchases is unsupported. Either result still needs server readback.
  Future<SubscriptionPurchaseResult> restore();
}

abstract interface class SubscriptionHostedUiGateway {
  Future<SubscriptionPurchaseResult> presentPaywall();
  Future<void> presentCustomerCenter();
}
