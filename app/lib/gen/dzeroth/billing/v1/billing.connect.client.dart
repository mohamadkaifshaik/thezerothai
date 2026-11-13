//
//  Generated code. Do not modify.
//  source: dzeroth/billing/v1/billing.proto
//

import "package:connectrpc/connect.dart" as connect;
import "billing.pb.dart" as dzerothbillingv1billing;
import "billing.connect.spec.dart" as specs;

extension type BillingServiceClient (connect.Transport _transport) {
  /// A missing subscription is Free; unavailable verification is explicitly
  /// reported as unknown, never silently converted to a confirmed Free tier.
  Future<dzerothbillingv1billing.GetMySubscriptionResponse> getMySubscription(
    dzerothbillingv1billing.GetMySubscriptionRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.BillingService.getMySubscription,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Informational plan catalog. Localized provider/store data, not this message,
  /// is the purchase price authority. No plan is purchasable during foundation.
  Future<dzerothbillingv1billing.GetAvailablePlansResponse> getAvailablePlans(
    dzerothbillingv1billing.GetAvailablePlansRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.BillingService.getAvailablePlans,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Idempotent allocation/lookup for this authenticated active account only.
  /// The returned opaque ID is PRIVATE; never put it in profiles, logs, analytics
  /// or shared URLs. This RPC alone does not enable a purchase or grant access.
  Future<dzerothbillingv1billing.EnsureBillingIdentityResponse> ensureBillingIdentity(
    dzerothbillingv1billing.EnsureBillingIdentityRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.BillingService.ensureBillingIdentity,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }
}
