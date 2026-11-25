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
/// already encrypted keep sending. Read live at each send; a cached flag set
/// counts (fails closed).
const kFeatureE2eeRequired = 'e2ee_required';

/// The most people one share action may be sent to (design Q7).
const kSharePostMaxRecipients = 5;

/// How many people of the cached inbox the share picker lists under "Recent".
const kSharePostRecentMax = 5;
