import 'package:flutter/foundation.dart';

import '../../../core/storage/app_database.dart';
import '../../../gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import '../../../gen/dzeroth/identity/v1/identity.pbenum.dart' show DmPolicy;
import '../../onboarding/data/identity_repository.dart';
import '../domain/message_privacy.dart';

/// The caller's message-privacy settings (F3 read receipts, F9 who can
/// message) **as the server last answered them this session**.
///
/// Why not `OnboardingBloc.state.profile`: the local profile cache keeps
/// neither field, and every refresh first re-emits the cached profile (with
/// receipts off and the policy unspecified) until `GetMe` answers, or for good
/// when it fails. A switch reading that would show a privacy state the server
/// never confirmed.
///
/// Fed by every `GetMe` answer (the app wires
/// `IdentityRepository.addGetMeListener`, 0 extra RPCs) and by the
/// `UpdateProfile` answers of the Settings switches. In memory only; reset
/// with the account session (sign-out or a switch of account), and readers
/// also compare [OwnPrivacy.userId] with the signed-in uid. Never logged.
class OwnPrivacyStore extends ValueNotifier<OwnPrivacy?> {
  OwnPrivacyStore() : super(null);

  /// Records the server's [profile] of the caller.
  void record(identity.Profile profile) {
    if (profile.userId.isEmpty) return;
    value = ownPrivacyOf(profile);
  }

  /// Forgets everything (the account session ended).
  void clear() => value = null;
}

/// The message-privacy part of the caller's own [profile].
OwnPrivacy ownPrivacyOf(identity.Profile profile) => OwnPrivacy(
  userId: profile.userId,
  readReceipts: profile.readReceipts,
  whoCanMessage: whoCanMessageOf(profile.dmPolicy),
);

/// UNSPECIFIED (every account from before the setting) is Everyone.
WhoCanMessage whoCanMessageOf(DmPolicy policy) =>
    policy == DmPolicy.DM_POLICY_FOLLOWING_ONLY
    ? WhoCanMessage.following
    : WhoCanMessage.everyone;

/// The wire value of [who]; never UNSPECIFIED (the server rejects it).
DmPolicy dmPolicyOf(WhoCanMessage who) => switch (who) {
  WhoCanMessage.everyone => DmPolicy.DM_POLICY_EVERYONE_REQUESTS,
  WhoCanMessage.following => DmPolicy.DM_POLICY_FOLLOWING_ONLY,
};

/// Feeds [store] every `GetMe` answer of [identityRepository] (0 extra
/// RPCs). An answer of an ended session (its epoch no longer allowed) is
/// dropped; [isLive] false (the owner was disposed) stops feeding.
void feedOwnPrivacyStore(
  OwnPrivacyStore store, {
  required IdentityRepository identityRepository,
  required AppDatabase database,
  bool Function()? isLive,
}) {
  identityRepository.addGetMeListener((response, epoch) {
    if (isLive != null && !isLive()) return;
    if (!database.sessionEpoch.allows(epoch)) return;
    store.record(response.profile);
  });
}
