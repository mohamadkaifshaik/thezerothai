import 'package:uuid/uuid.dart';

import '../../../../core/network/api_client.dart';
import '../../../../gen/dzeroth/billing/v1/billing.pb.dart' as wire;
import '../domain/subscription_models.dart';
import 'subscription_sources.dart';

/// Uses the shared authenticated transport; owner identity is never sent in RPCs.
class ConnectSubscriptionStatusSource implements SubscriptionStatusSource {
  ConnectSubscriptionStatusSource({
    required ApiClient api,
    required String? Function() currentUid,
  }) : _api = api,
       _currentUid = currentUid;

  final ApiClient _api;
  final String? Function() _currentUid;

  String _owner() {
    final uid = _currentUid();
    if (uid == null || uid.isEmpty) throw StateError('Sign in required');
    return uid;
  }

  void _checkOwner(String uid) {
    if (_currentUid() != uid) throw StateError('Subscription session changed');
  }

  @override
  Future<SubscriptionAccess> getAccess() async {
    final uid = _owner();
    final response = await guardApiCall(
      () => _api.billing.getMySubscription(wire.GetMySubscriptionRequest()),
    );
    _checkOwner(uid);
    return SubscriptionAccess(
      uid: uid,
      tier: switch (response.tier) {
        wire.SubscriptionTier.SUBSCRIPTION_TIER_FREE => SubscriptionTier.free,
        wire.SubscriptionTier.SUBSCRIPTION_TIER_PLUS => SubscriptionTier.plus,
        wire.SubscriptionTier.SUBSCRIPTION_TIER_PREMIUM =>
          SubscriptionTier.premium,
        _ => SubscriptionTier.unknown,
      },
      verification: switch (response.verificationState) {
        wire.VerificationState.VERIFICATION_STATE_NO_SUBSCRIPTION =>
          SubscriptionVerification.noSubscription,
        wire.VerificationState.VERIFICATION_STATE_VERIFIED =>
          SubscriptionVerification.verified,
        _ => SubscriptionVerification.unavailable,
      },
      verifiedAt: response.hasVerifiedAt()
          ? response.verifiedAt.toDateTime()
          : null,
      validUntil: response.hasAccessUntil()
          ? response.accessUntil.toDateTime()
          : null,
      purchasesAvailable: response.purchasesAvailable,
    );
  }

  @override
  Future<String> ensureBillingIdentity() async {
    final uid = _owner();
    final request = wire.EnsureBillingIdentityRequest(
      idempotencyKey: const Uuid().v4(),
    );
    final response = await guardApiCall(
      () => _api.billing.ensureBillingIdentity(request),
    );
    _checkOwner(uid);
    return response.appUserId;
  }
}
