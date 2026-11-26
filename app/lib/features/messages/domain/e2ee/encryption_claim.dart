import '../../../../core/app_build.dart';
import '../../../../core/vault/vault_status.dart';
import '../messaging_feature_flag.dart';

/// The vault states in which the claim may be shown: only an open vault.
///
/// Fix round 1 (code review M1): `heldElsewhere` is out. The rest of the app
/// treats it as "not open" (`EncryptionStatus.blocksMessaging`), so this tab
/// cannot read or send encrypted messages. Every other state hides the claim
/// as well: `unsupported` has no vault; `unavailable`, `keyLost` and
/// `storageChanged` cannot open now; `off` means encryption has not started
/// on this device; `opening` has not opened yet, so the headline appears once
/// the vault opens instead of showing and then vanishing if the open fails.
const kClaimVaultStates = {VaultStatus.ready};

/// Whether the "We cannot read your messages." headline (and with it the
/// About page's claim text) may be shown. Pure. Every one of these must hold
/// (Plan 6 §4.1 conditions 1, 5 and 6, Task 4.A, fix round 1):
///
/// - [featuresKnown]: [features] is a known flag set (not
///   `featuresPending`) of the signed-in user (the state's user is the
///   signed-in one, as `e2eeRequiredFor` checks). Fails closed otherwise
///   (code review m2);
/// - [features] (the caller's `enabled_features`) holds [kFeatureClaimLive]
///   (the server's switch) AND [kFeatureE2eeRequired]. The server couples them
///   already, and since 3d9168f5 it also requires `device_sign_out`. The
///   client checks both itself so that a stale or inconsistent set never
///   shows the claim;
/// - this build's capability level on [platform] (`clientPlatformName()`) is
///   at least 1. It is 0 wherever there is no crypto engine
///   (`clientLevelFor`, tied to engine support by the capability guard);
/// - [platform] is not `ios`, checked directly: the copy says encrypted
///   messages are not available in the iPhone and iPad app, so even an iOS
///   engine landing later must not show this text until the copy changes;
/// - [vault] is one of [kClaimVaultStates];
/// - ![messagingBlocked]: the device's encryption status does not block
///   messaging (`EncryptionStatus.blocksMessaging`, for example an
///   unavailable engine or a device removed elsewhere; code review m1).
bool claimVisible({
  required bool featuresKnown,
  required Set<String> features,
  required String platform,
  required VaultStatus vault,
  required bool messagingBlocked,
}) {
  if (!featuresKnown) return false;
  if (!features.contains(kFeatureClaimLive)) return false;
  if (!features.contains(kFeatureE2eeRequired)) return false;
  if (platform == 'ios') return false;
  if (clientLevelFor(platform) < 1) return false;
  if (messagingBlocked) return false;
  return kClaimVaultStates.contains(vault);
}
