//
//  Generated code. Do not modify.
//  source: dzeroth/billing/v1/billing.proto
//

import "package:connectrpc/connect.dart" as connect;
import "billing.pb.dart" as dzerothbillingv1billing;

abstract final class BillingService {
  /// Fully-qualified name of the BillingService service.
  static const name = 'dzeroth.billing.v1.BillingService';

  /// A missing subscription is Free; unavailable verification is explicitly
  /// reported as unknown, never silently converted to a confirmed Free tier.
  static const getMySubscription = connect.Spec(
    '/$name/GetMySubscription',
    connect.StreamType.unary,
    dzerothbillingv1billing.GetMySubscriptionRequest.new,
    dzerothbillingv1billing.GetMySubscriptionResponse.new,
  );

  /// Informational plan catalog. Localized provider/store data, not this message,
  /// is the purchase price authority. No plan is purchasable during foundation.
  static const getAvailablePlans = connect.Spec(
    '/$name/GetAvailablePlans',
    connect.StreamType.unary,
    dzerothbillingv1billing.GetAvailablePlansRequest.new,
    dzerothbillingv1billing.GetAvailablePlansResponse.new,
  );

  /// Idempotent allocation/lookup for this authenticated active account only.
  /// The returned opaque ID is PRIVATE; never put it in profiles, logs, analytics
  /// or shared URLs. This RPC alone does not enable a purchase or grant access.
  static const ensureBillingIdentity = connect.Spec(
    '/$name/EnsureBillingIdentity',
    connect.StreamType.unary,
    dzerothbillingv1billing.EnsureBillingIdentityRequest.new,
    dzerothbillingv1billing.EnsureBillingIdentityResponse.new,
  );
}
