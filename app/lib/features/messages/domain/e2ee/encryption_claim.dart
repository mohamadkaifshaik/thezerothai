import '../../../../core/app_build.dart';
import '../../../../core/vault/vault_status.dart';
import '../messaging_feature_flag.dart';

/// The vault states in which the claim may be shown: a vault that opens on
/// this device. `ready` is open; `heldElsewhere` (web) is open in another tab
/// of the same browser, so encrypted messages work for this user here.
///
/// Every other state hides it. Why each one (Plan 6 §4.1 condition 6, "the
/// vault can open"): `unsupported` has no vault; `unavailable`, `keyLost` and
/// `storageChanged` cannot open now; `off` means encryption has not started on
/// this device; `opening` has not opened yet (the headline appears once it
/// has, rather than showing and then vanishing if the open fails).
const kClaimVaultStates = {VaultStatus.ready, VaultStatus.heldElsewhere};

/// Whether the "We cannot read your messages." headline (and with it the
/// About page's claim text) may be shown. Pure. All must hold (Plan 6 §4.1
/// conditions 1 and 6, Task 4.A):
///
/// - [features] (the caller's `enabled_features`) holds [kFeatureClaimLive],
///   the server's switch, AND [kFeatureE2eeRequired]: the server couples the
///   two already; the client checks both so a stale or inconsistent set
///   never shows the claim;
/// - this build's capability level on [platform] (`clientPlatformName()`) is
///   at least 1, which is 0 wherever there is no crypto engine
///   (`clientLevelFor`, bound to engine support by the capability guard);
/// - [platform] is not `ios`, explicitly: the copy says encrypted messages
///   are not available on iPhone and iPad, so even an iOS engine landing
///   later must not show this text until the copy changes;
/// - [vault] is one of [kClaimVaultStates].
bool claimVisible({
  required Set<String> features,
  required String platform,
  required VaultStatus vault,
}) {
  if (!features.contains(kFeatureClaimLive)) return false;
  if (!features.contains(kFeatureE2eeRequired)) return false;
  if (platform == 'ios') return false;
  if (clientLevelFor(platform) < 1) return false;
  return kClaimVaultStates.contains(vault);
}
