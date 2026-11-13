/// Server feature flag for direct messages, mirrored to the
/// client via `GetMe.enabled_features`.
const kFeatureMessaging = 'messaging';

/// Server feature flag for sending a post in a message
/// (`SendMessageRequest.shared_post_id`), per caller. It gates only the send
/// side (the "Send in a message" row and the picker); a message that carries
/// a post is drawn as a card whatever this flag says for the viewer.
const kFeatureDmPostShare = 'dm_post_share';

/// The most people one share action may be sent to (design Q7).
const kSharePostMaxRecipients = 5;

/// How many people of the cached inbox the share picker lists under "Recent".
const kSharePostRecentMax = 5;
