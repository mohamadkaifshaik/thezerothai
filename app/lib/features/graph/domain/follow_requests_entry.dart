import '../../settings/domain/private_accounts_feature_flag.dart';
import 'graph_feature_flag.dart';

/// The one rule for "may this caller open Follow requests" (W3-34, W3-34b).
///
/// `/follow-requests` is allowed when `graph` is on and the caller is protected
/// or has `private_accounts`. A protected caller keeps it with
/// `private_accounts` off everywhere: requests are never lost to a flag (the
/// undo rule, ADR-0025 D12). The router redirect, the drawer row and the
/// account menu entry of wide layouts all call this, so they cannot drift.
///
/// Respond (Accept / Decline) is not gated by anything else here.
bool followRequestsAllowed({
  required Set<String> enabledFeatures,
  required bool isProtected,
}) =>
    enabledFeatures.contains(kFeatureGraph) &&
    (enabledFeatures.contains(kFeaturePrivateAccounts) || isProtected);
