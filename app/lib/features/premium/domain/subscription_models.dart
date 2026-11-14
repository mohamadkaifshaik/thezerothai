/// Logical account tiers. Unknown wire values must map to [unknown], which
/// never grants paid UI capabilities. The Go API authorizes every mutation.
enum SubscriptionTier { unknown, free, plus, premium }

enum SubscriptionVerification { noSubscription, verified, unavailable }

/// A server response scoped to one signed-in account. SDK CustomerInfo and
/// checkout redirects must never be converted directly into this model.
class SubscriptionAccess {
  const SubscriptionAccess({
    required this.uid,
    required this.tier,
    required this.verification,
    this.verifiedAt,
    this.validUntil,
    this.purchasesAvailable = false,
  });

  final String uid;
  final SubscriptionTier tier;
  final SubscriptionVerification verification;
  final DateTime? verifiedAt;

  /// Server-calculated minimum of access expiry/grace and freshness deadline.
  final DateTime? validUntil;
  final bool purchasesAvailable;

  /// Null means uncertain, not confirmed Free. Keep billing support available
  /// and show a retry state instead of offering a duplicate subscription.
  SubscriptionTier? effectiveTier(DateTime now) {
    if (verification == SubscriptionVerification.noSubscription) {
      return tier == SubscriptionTier.free ? SubscriptionTier.free : null;
    }
    final checked = verifiedAt;
    final until = validUntil;
    if (verification != SubscriptionVerification.verified ||
        checked == null ||
        until == null ||
        checked.isAfter(now) ||
        !now.isBefore(until) ||
        !now.isBefore(checked.add(const Duration(minutes: 15))) ||
        tier == SubscriptionTier.unknown) {
      return null;
    }
    return tier;
  }
}

/// An offering loaded from the active storefront/checkout provider. The
/// existing PremiumPlan rupee values remain informational coming-soon copy.
class SubscriptionOffering {
  const SubscriptionOffering({
    required this.packageIdentifier,
    required this.productIdentifier,
    required this.tier,
    required this.localizedPrice,
    required this.billingPeriod,
  });

  final String packageIdentifier;
  final String productIdentifier;
  final SubscriptionTier tier;
  final String localizedPrice;
  final String billingPeriod;
}

enum PurchaseDisposition { verifying, canceled, pending, refreshed }

/// Even a successful store transaction only starts server verification.
class SubscriptionPurchaseResult {
  const SubscriptionPurchaseResult(this.disposition);

  final PurchaseDisposition disposition;
}
