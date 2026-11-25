import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../onboarding/presentation/bloc/onboarding_state.dart';

/// Server feature flag for direct messages, mirrored to the
/// client via `GetMe.enabled_features`.
const kFeatureMessaging = 'messaging';

/// Server feature flag for sending a post in a message
/// (`SendMessageRequest.shared_post_id`), per caller. It gates only the send
/// side (the "Send in a message" row and the picker); a message that carries
/// a post is drawn as a card whatever this flag says for the viewer.
const kFeatureDmPostShare = 'dm_post_share';

/// Server feature flag for `CheckPostShare`, the server's share check an
/// encrypted post share asks before it sends, per caller. While it is not in
/// the caller's enabled features the app refuses an encrypted post share
/// (there is no other check). Its FEATURE_DISABLED is shown as
/// [kFeatureDmPostShare].
const kFeatureDmShareCheck = 'dm_share_check';

/// Server feature flag for end-to-end encrypted direct messages, per
/// caller. It gates STARTING encryption. A user with no vault on this device
/// and the flag off or unknown opens no vault, generates no key and makes no
/// key-directory or MLS call; a vault that already exists opens whatever the
/// flag says (`VaultSession`).
const kFeatureE2eeDm = 'e2ee_dm';

/// Server feature flag (Plan 6 §1.1, Task 1.B): every NEW send must be
/// end-to-end encrypted. The server lists the effective value, `e2ee_required
/// && messaging`, which is NOT gated by [kFeatureE2eeDm] (PR 6-1 security
/// review M2: it fails closed), so the client may see it without `e2ee_dm`.
/// While it is in the caller's enabled features the app never makes a
/// plaintext `SendMessage`: an empty peer device list is refused
/// (`peerHasNoDevice`), and with `e2ee_dm` off a conversation that is not
/// encrypted yet offers no send at all (`requiredUnavailable`). Conversations
/// already encrypted keep sending. Read live at each send through
/// [e2eeRequiredOf], which also answers "required" while the flag set is not
/// known (fails closed).
const kFeatureE2eeRequired = 'e2ee_required';

/// Plan 6 Task 1.B (security review L1): whether a plaintext send must be
/// refused under `e2ee_required` for the onboarding state [state], emitted
/// for [stateUid], while [signedInUid] is signed in. Fails closed: the answer
/// is "required" while the flag set is not known ([OnboardingState.
/// featuresPending]: no GetMe answer yet this session; flags are never
/// persisted) and while the state is another user's (a switch the onboarding
/// state has not caught up with). Only a known flag set of the signed-in user
/// without `e2ee_required` answers false.
bool e2eeRequiredFor(
  OnboardingState state, {
  required String? stateUid,
  required String? signedInUid,
}) {
  if (state.featuresPending) return true;
  if (stateUid != signedInUid) return true;
  return state.enabledFeatures.contains(kFeatureE2eeRequired);
}

/// The ONE reader of `e2ee_required` every plaintext-capable sender is given
/// (`encryptionRequired:` of the composer, the share cubit and the E2EE
/// pipeline; the plaintext-send guard pins that). Reads [bloc] live, with the
/// fail-closed rule of [e2eeRequiredFor]. [signedInUid] is the authenticated
/// user (bootstrap passes the auth bloc's); by default the user [bloc] itself
/// serves ([OnboardingBloc.currentUid]), which a screen can read without the
/// auth bloc.
bool Function() e2eeRequiredOf(
  OnboardingBloc bloc, {
  String? Function()? signedInUid,
}) {
  return () => e2eeRequiredNow(bloc, signedInUid: signedInUid);
}

/// [e2eeRequiredOf]'s answer now: what a widget selects on
/// (`context.select((OnboardingBloc b) => e2eeRequiredNow(b))`), so a note
/// shown beside the composer follows the same fail-closed rule as its sends
/// and rebuilds when the onboarding state changes (code review Nit 1).
bool e2eeRequiredNow(OnboardingBloc bloc, {String? Function()? signedInUid}) {
  final state = bloc.state;
  return e2eeRequiredFor(
    state,
    stateUid: bloc.uidOf(state),
    signedInUid: signedInUid == null ? bloc.currentUid : signedInUid(),
  );
}

/// The most people one share action may be sent to (design Q7).
const kSharePostMaxRecipients = 5;

/// How many people of the cached inbox the share picker lists under "Recent".
const kSharePostRecentMax = 5;
