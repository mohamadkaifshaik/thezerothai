//
//  Generated code. Do not modify.
//  source: dzeroth/messaging/v1/messaging.proto
//

import "package:connectrpc/connect.dart" as connect;
import "messaging.pb.dart" as dzerothmessagingv1messaging;
import "messaging.connect.spec.dart" as specs;

extension type MessagingServiceClient (connect.Transport _transport) {
  /// Send a text message, opening the conversation if needed. Target: recipient_user_id (opens or continues the 1:1
  /// conversation with that user; self => VALIDATION "recipient_user_id"; [A-Za-z0-9-]{1,128}) or conversation_id (an
  /// existing conversation the caller is a participant of, else NOT_FOUND).
  /// text: the post grammar (NFC, <= 280 code points, <= 10 lines; testdata fixtures), validated before any read
  /// (VALIDATION "text").
  /// Flag: per caller AND per recipient. Caller off => FEATURE_DISABLED; recipient off => CANNOT_MESSAGE.
  /// The caller needs a verified email (FAILED_PRECONDITION EMAIL_NOT_VERIFIED, before any lookup), as for posts.
  /// Refusals, all CANNOT_MESSAGE with identical bytes: either side blocks the other (the caller's graph
  /// snapshot, cached 60 s, and the recipient's graph read inside the send transaction, so the recipient's Block applies
  /// at once on every instance),
  /// the recipient is not ACTIVE or has messaging off, the conversation is gone (the peer deleted the account).
  /// Routing: a new conversation is ACCEPTED when the two follow each other, else REQUEST (the recipient's entry goes
  /// to REQUESTS). While REQUEST, the requester may send MESSAGES_REQUEST_MAX_UNANSWERED (3) messages, then
  /// LIMIT_REACHED "request_unanswered"; a message from the recipient of the request accepts it (as on X). The
  /// recipient muted the caller => delivered silently (no unread increment, no push).
  /// Idempotency (the bend of rules 1 and 4): the message id is the first 32 hex characters
  /// of SHA-256(sender auth uid || "|SendMessage|" || idempotency_key) (ASCII, lower-case hex), and Created in the send
  /// transaction, so a retry returns the stored message and writes nothing; the same key with a different body =>
  /// VALIDATION "idempotency_key". Idempotency keys must carry at least 128 random bits. Clients dedupe by message id.
  /// Caps: RATE_LIMIT_MESSAGES_SEND_PER_MIN 20/min/uid per instance (60/min at 3 instances);
  /// MESSAGES_SENDS_PER_DAY 300 (50 for new accounts) per instance (<= 900/day at 3) => RATE_LIMITED metadata["limit"]
  /// = "messages_daily"; QUOTA_DM_NEW_CONVERSATIONS_PER_DAY 20 new conversations per IST day (5 for new accounts),
  /// exact (quotas/{uid}.dmNew, in the transaction, the one persisted daily counter left besides reports) => LIMIT_REACHED "dm_new_daily"; MESSAGES_REQUEST_MAX_UNANSWERED 3,
  /// exact (conversations.requestCount, in the transaction).
  /// Push: after the commit one `message` event through notifications.Emitter (one Pub/Sub publish, 0 Firestore on
  /// this path), only when the recipient's side is accepted and not silent; a request never pushes. The push is
  /// generic ("New message") and carries only the conversation id (NOTIFICATION_TYPE_MESSAGE).
  /// A refused send writes nothing.
  /// Sharing a post (shared_post_id set): every rule above applies unchanged (blocks, DM policy, requests, caps, push).
  /// In addition, before the send transaction and after the recipient checks:
  /// - Flag FEATURE_DM_POST_SHARE (wire name "dm_post_share"): on for the caller (else FAILED_PRECONDITION +
  ///   FEATURE_DISABLED, metadata["feature"] = "dm_post_share", before any lookup); FEATURE_POSTS must be on.
  /// - shared_post_id: 19 digits (else VALIDATION "shared_post_id", before any lookup). A REPOST id shares its original;
  ///   the stored and returned id is the original's.
  /// - The post must be visible to the caller by the GetPost rules (missing, deleted, hidden, suspended or deleting
  ///   author, an author who blocks the caller, a QUOTE or REPOST whose embedded author blocks the caller), and by the
  ///   card's rule: no block in either direction, so a caller who blocked the author (or a QUOTE's embedded author) may
  ///   not send it either. Every case => NOT_FOUND "post not found", byte-identical to GetPost, writing nothing.
  /// - Protected authors: a post by a protected account may be sent only by that account (the RepostPost rule); any
  ///   other caller who can see it => FAILED_PRECONDITION + PROTECTED_ACCOUNT, writing nothing.
  /// - The client sends a text even without a caption: the canonical post URL (so a client that predates the card shows a
  ///   link that opens through GetPost). A client that renders shared_post hides a text equal to that URL.
  /// - Idempotency: shared_post_id is part of the request body, so the same key with a different post => VALIDATION
  ///   "idempotency_key", like a different text.
  /// - The message document stores the post id only, never a copy of the post: Message.shared_post is decided for each
  ///   reader at read time (ListMessages). The inbox preview never carries post text (MessagePreview.shared_post).
  /// - After the commit (never for a replay or a refusal, and never inside the send transaction, so a hot post cannot
  ///   abort a DM) the share is recorded once per (caller, post) for Post.share_count when FEATURE_SHARE_COUNT is not
  ///   globally off and the caller is not the post's author: best effort, a failure is logged and never fails the send.
  /// Worst case added by a share: the post visibility check (cache-first: the post, its author's status, the caller's
  /// graph already read, the protected set; 0-3 reads), then on a first share by this caller of this post 1 read
  /// (postShares marker) + 2 writes (marker Create, posts.shareCount Increment); 1 read and 0 writes otherwise.
  /// Encrypted messages (file comment, "End-to-end encryption"). A request with any of ciphertext, report_commitment,
  /// mls_generation, mls_epoch or mls_init set is an encrypted request:
  /// - Validation of the FORMAT of the encrypted fields, before any lookup: text and shared_post_id must be empty
  ///   (VALIDATION "text" / "shared_post_id"; the text and any shared post id travel inside the ciphertext as
  ///   MessageContent); ciphertext 1-8192 bytes (VALIDATION "ciphertext"); report_commitment exactly 32 bytes
  ///   (VALIDATION "report_commitment"); mls_generation and mls_epoch 1 to 2^63 - 1, and exactly (1, 1) with mls_init
  ///   (VALIDATION "mls_generation" / "mls_epoch"); with mls_init the MlsInit format rules (VALIDATION "commit",
  ///   "welcome" or "welcome_device_ids").
  /// - Order of answers: every existing refusal (verified email, NOT_FOUND, CANNOT_MESSAGE for gone, blocks, policy or
  ///   flag, LIMIT_REACHED, rate limits) keeps its order and bytes and comes first. Then, in this order and before any
  ///   write: the welcome-device (active) check (VALIDATION "welcome_device_ids"); ENCRYPTION_REQUIRED or VALIDATION
  ///   "ciphertext" (an encrypted send without mls_init into a NONE or new conversation), which cannot both apply;
  ///   STALE_EPOCH. Only the device check and STALE_EPOCH can both apply (on mls_init); the device check answers first.
  ///   A replay (the message of this idempotency_key already stored with the same request) wins over all of them.
  /// - Into an MLS conversation without mls_init: the pair must equal the conversation's current pair, compared inside
  ///   the send transaction, else STALE_EPOCH (current pair in metadata), storing nothing.
  /// - Into a NONE conversation, or opening a new one, without mls_init => VALIDATION "ciphertext".
  /// - A plaintext request (none of those fields) into an MLS conversation, by conversation_id or by recipient_user_id
  ///   => FAILED_PRECONDITION + ENCRYPTION_REQUIRED, storing nothing (entries and unread counts untouched).
  /// - STALE_EPOCH and ENCRYPTION_REQUIRED for a request that addressed recipient_user_id also carry
  ///   metadata["conversation_id"] (the caller is then a participant of that existing conversation), so the client can
  ///   continue by conversation id.
  /// - mls_init starts encryption: it creates the conversation as MLS (no conversation yet) or converts a NONE one (the
  ///   caller must be a participant; else the one NOT_FOUND). Flag e2ee_dm on for the caller (FEATURE_DISABLED
  ///   "e2ee_dm", before any lookup) and the recipient (CANNOT_MESSAGE). All existing send rules (blocks, DM policy,
  ///   requests and their cap, verified email, rate limits, dm_new_daily) apply unchanged and their refusals stay
  ///   byte-identical. In the transaction: a retried mls_init whose message already exists (same idempotency_key, same
  ///   request) is a replay and returns the stored message; any other mls_init that finds the conversation already MLS
  ///   => STALE_EPOCH with its pair (another device started first: join through ListWelcomes); else the conversation
  ///   becomes MLS at generation 1, epoch 1, the commit record (1, 0) is created with mls_init.commit, the welcomes are
  ///   stored (MlsInit), and the message is stored at (1, 1); all in the one send transaction, or none of it.
  ///   The retry is recognised inside the transaction, so the refusals before it still answer first: FEATURE_DISABLED
  ///   "e2ee_dm" if the caller has since lost the flag, CANNOT_MESSAGE if the recipient has (or blocked the caller),
  ///   although the message is stored. The client treats the init as possibly stored and checks ListMessages.
  /// - Stored and returned: text empty, ciphertext, report_commitment, the pair; no shared post id. The server cannot
  ///   check a shared post's visibility or the protected-author rule for an encrypted message: the sending app applies
  ///   them through CheckPostShare (and FEATURE_DM_POST_SHARE), the reader's app opens the card through
  ///   PostService.GetPost, which decides for the reader; Post.share_count does not count encrypted shares. Previews:
  ///   snippet empty, encrypted = true, shared_post false. Unread, silent, request routing and push are unchanged (the push carries no content).
  /// - Idempotency: unchanged rule, the message id derives from (caller, idempotency_key); the request identity of an
  ///   encrypted send covers the conversation, the pair, the ciphertext and the report commitment. A lost response is
  ///   retried with the SAME key and the IDENTICAL saved ciphertext, commitment and pair, and returns the stored message
  ///   even if the epoch has moved on since (a replay wins over STALE_EPOCH). The same key with a request differing in
  ///   any of them => VALIDATION "idempotency_key" as for a different text, except that a message a moderator took down
  ///   replays as its REMOVED tombstone (ciphertext_removed = true) whatever the request, as for plaintext. A
  ///   STALE_EPOCH refusal stores nothing, so the key is not consumed; the
  ///   message re-encrypted after it is a new request: send it with a NEW idempotency key (the client saves the new
  ///   bytes and key together before calling).
  /// - Cost: an encrypted send in an MLS conversation reads and writes exactly what a plaintext send does. "No
  ///   conversation write" holds only in an ACCEPTED conversation: in a REQUEST conversation the send still writes
  ///   requestCount, and a reply by the recipient that accepts the request still writes state, as for plaintext. A
  ///   refusal on an existing conversation (ENCRYPTION_REQUIRED, VALIDATION "ciphertext", STALE_EPOCH) adds 1 read,
  ///   the replay check of the message id. mls_init adds the device checks (at most 2 queries of at most 5 device
  ///   documents) and, in the transaction, at most 11 reads (the earlier welcome of each addressed device, to replace
  ///   it, and the (1, 0) commit record) and at most 2 + 20 = 22 more writes (the conversation's encryption fields, 0 when the send already creates
  ///   or updates the conversation; the commit record; per device one welcome and the delete of the earlier one).
  Future<dzerothmessagingv1messaging.SendMessageResponse> sendMessage(
    dzerothmessagingv1messaging.SendMessageRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.MessagingService.sendMessage,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Answers whether the caller may share a post in a direct message, by the very rules SendMessage applies to
  /// shared_post_id (same function, same order, same bytes), without a recipient or a conversation and writing
  /// nothing. For an ENCRYPTED share the post id travels inside the ciphertext, so the sending app calls this once per
  /// share action before encrypting, and sends only on success. A plaintext share does not need it (SendMessage checks).
  /// Gates, in SendMessage's order, all before any lookup: "messaging" on for the caller; FEATURE_DM_SHARE_CHECK
  /// ("dm_share_check") on for the caller; a verified email (EMAIL_NOT_VERIFIED); "posts" and "dm_post_share" on for the
  /// caller (FAILED_PRECONDITION + FEATURE_DISABLED, metadata["feature"] = the off flag); post_id 19 digits (VALIDATION
  /// "post_id").
  /// Answers, byte-identical to SendMessage with shared_post_id except one: a raw read failure (a timeout or contention
  /// reading the post or the directory) is INTERNAL here (SendMessage: UNAVAILABLE "busy, please retry"), so the client's
  /// automatic retry of NO_SIDE_EFFECTS calls on UNAVAILABLE does not fire on it. NOT_FOUND "post not found" when the caller may not see
  /// the post by the GetPost rules or a block stands either way between the caller and its author (or a QUOTE's or the
  /// REPOST original's embedded author); FAILED_PRECONDITION + PROTECTED_ACCOUNT for a protected author's post shared by
  /// anyone else; UNAVAILABLE "temporarily busy, please retry" when the protected set cannot be read. A REPOST id is
  /// checked on itself and on its original, and shared_post_id names the original.
  /// Success is not a promise: the post or the graph can change before the send; the reader's app decides the card again.
  /// Rate limit: RATE_LIMIT_MESSAGES_SHARE_CHECK_PER_MIN 10/min/uid per instance; MESSAGES_SHARE_CHECKS_PER_DAY 300 per
  /// instance (RATE_LIMITED metadata["limit"] = "messages_share_checks_daily"). Answers under DEGRADED_MODE=readonly.
  /// Cost: SendMessage's share check, cache-first: 0-3 reads (the post and, for a REPOST, its original; author status
  /// through the directory, 60 s; caller graph, 60 s; the protected set). Writes nothing; never records a share.
  Future<dzerothmessagingv1messaging.CheckPostShareResponse> checkPostShare(
    dzerothmessagingv1messaging.CheckPostShareRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.MessagingService.checkPostShare,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// The caller's conversations in one folder, most recent activity first. The path comes from the caller's token;
  /// there is no user id parameter. folder must be INBOX or REQUESTS, else VALIDATION "folder".
  /// Read-time rules (caller graph, cached 60 s): REQUESTS drops entries whose peer the caller blocks or mutes, or who
  /// blocks the caller (a caller past the blockedBy cap also checks each REQUESTS peer's graph, cached 60 s); INBOX
  /// keeps every entry, with can_reply = false when either side blocks. Filtering runs after
  /// the page query, so a page may be short or empty while next_page_token is non-empty: keep following it.
  /// request_count is set on every INBOX first page and since refresh (an empty refresh included); 0 on an older page and
  /// on REQUESTS. Clients treat the INBOX value as authoritative, 0 included.
  /// There is no gap_page_token here: a since refresh returns at most page_size entries.
  /// Flag: not globally off. Rate limit: RATE_LIMIT_MESSAGES_READ_PER_MIN 30/min/uid per instance (90/min at 3),
  /// shared with ListMessages.
  Future<dzerothmessagingv1messaging.ListConversationsResponse> listConversations(
    dzerothmessagingv1messaging.ListConversationsRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.MessagingService.listConversations,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Messages of one conversation, newest first. Messages at or before the caller's own DeleteConversation time are
  /// not returned. Tombstones (state DELETED_ACCOUNT or REMOVED) are returned with empty text.
  /// conversation is set on a first or older page (live peer snapshot from the identity directory, 60 s; can_reply
  /// from the caller graph, 60 s) and UNSET on a since response, so a poll reads no peer profile or graph.
  /// On the first page only, conversation.unread_count and conversation.silent come from the caller's own entry (0 and
  /// false when it is gone); on an older page they are unset. When the peer blocked the caller, conversation.peer is the
  /// snapshot frozen on the caller's entry, not the live profile ("Deleted account" on an older page or when the entry is
  /// gone), and can_reply is false.
  /// A since refresh whose page was full returns gap_page_token: keep the cache and fill the gap with page_token =
  /// gap_page_token (bounded below by the old since_token).
  /// Client polling: only on a visible thread; web 15 s while hot, Android 30 s while hot, 45 s while
  /// quiet, stopped after 5 min idle or when hidden; a push for the conversation triggers an immediate pull; a
  /// RATE_LIMITED answer pauses polling.
  /// Flag: not globally off. Rate limit: RATE_LIMIT_MESSAGES_READ_PER_MIN 30/min/uid per instance (90/min at 3),
  /// shared with ListConversations.
  /// Shared posts: every returned VISIBLE message that carries a post gets Message.shared_post, decided for the CALLER
  /// (the reader, sender or recipient alike) by the GetPost rules at read time, on every page kind including a since
  /// poll. Only the page's shared post ids are hydrated, in one batched cache-first read (posts.GetMany: at most one
  /// read per distinct post not in the instance cache, plus its author's status through the identity directory, 60 s);
  /// the caller's graph snapshot (60 s) is read only when the page carries a shared post; a caller past the blockedBy
  /// cap also consults each card author's graph (60 s, at most one per distinct author), as GetPost does. A since poll with no new
  /// shared post therefore still reads no post, profile or graph. While FEATURE_DM_POST_SHARE is globally off every
  /// card is the unavailable form.
  Future<dzerothmessagingv1messaging.ListMessagesResponse> listMessages(
    dzerothmessagingv1messaging.ListMessagesRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.MessagingService.listMessages,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Marks the conversation read for the caller: unread count 0 and the read time on the caller's own entry (a field
  /// update with an Exists precondition). The read time (last_read_at) is never shown to the peer. When the caller's "Read
  /// receipts" setting is on (identity Profile.read_receipts, FEATURE_READ_RECEIPTS on for the caller; read from the 60 s
  /// profile cache, no extra Firestore read) the same update also stores read_receipt_at on the caller's entry, which the
  /// peer can see as Conversation.peer_read_at only while both sides have receipts on (F3: opt-in, reciprocal, never
  /// retroactive: a read made while the setting was off stores no receipt). A missing
  /// entry (unknown id, non-participant, deleted for the caller) => success, writing nothing. Evicts the caller's
  /// unread_conversation_count cache on this instance. Call only when the client holds unread_count > 0.
  /// Flag: not globally off. Refused under DEGRADED_MODE=readonly.
  Future<dzerothmessagingv1messaging.MarkConversationReadResponse> markConversationRead(
    dzerothmessagingv1messaging.MarkConversationReadRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.MessagingService.markConversationRead,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Accepts a message request: the conversation becomes ACCEPTED and the caller's entry moves from REQUESTS to INBOX
  /// (unread count kept). Only the recipient of the request may accept; the requester (or a non-participant) gets
  /// NOT_FOUND. Already accepted => success, writing nothing. Emits nothing.
  /// Flag: per caller AND per recipient (the peer); peer off => CANNOT_MESSAGE. Refused under DEGRADED_MODE=readonly.
  /// The caller needs a verified email (FAILED_PRECONDITION EMAIL_NOT_VERIFIED, before any lookup), as for posts.
  /// Accepting updates the conversation state, the dmInbox entry and the requester's entry (request flag cleared,
  /// changedAt moved; skipped when the requester deleted that entry), and deletes the dmRequests entry.
  Future<dzerothmessagingv1messaging.AcceptMessageRequestResponse> acceptMessageRequest(
    dzerothmessagingv1messaging.AcceptMessageRequestRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.MessagingService.acceptMessageRequest,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Deletes the conversation for the caller only (also "delete request"): removes the caller's entry from either
  /// folder and hides every message up to now from the caller. The peer keeps the conversation. A deleted request stays
  /// a REQUEST for the sender, whose cap still applies; a later message recreates the caller's entry showing only newer
  /// messages. Blocking from a thread uses GraphService.Block and does not delete the conversation.
  /// Flag: not globally off. Refused under DEGRADED_MODE=readonly.
  /// Sets clearedAt on the conversation and deletes the caller's entry.
  Future<dzerothmessagingv1messaging.DeleteConversationResponse> deleteConversation(
    dzerothmessagingv1messaging.DeleteConversationRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.MessagingService.deleteConversation,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// People the caller is likely to message (F30), for the new-message screen. Computed on every call; nothing is stored.
  /// Sources, in this order (a person appears once, with the first reason that found them):
  /// 1. RECENT_CONVERSATION: the peers of the caller's newest 8 INBOX entries.
  /// 2. MET_ON_PLAN: the organiser and ACCEPTED participants of the caller's 2 most recent ended plans (FEATURE_BEACONS on
  ///    for the caller; the caller was the organiser or ACCEPTED; not hidden; ended within the last 30 days, the
  ///    beacons TTL), at most 4 rows read per plan. plan_activity is that plan's activity.
  /// 3. MUTUAL_FOLLOW: among the caller's 10 newest followees, those who follow the caller back.
  /// 4. COMMUNITY_MEMBER: the 6 newest JOINED members of the community the caller joined most recently (FEATURE_COMMUNITIES
  ///    on for the caller; an ACTIVE community). community_id and community_name name it.
  /// Every row is someone SendMessage would not refuse with CANNOT_MESSAGE at the time of the call, by the same rules:
  /// never the caller; not ACTIVE, messaging off for them, either side blocks the other (the caller's 60 s graph snapshot),
  /// or their "who can message me" policy is FOLLOWING_ONLY (with FEATURE_DM_POLICY on for them) and they do not follow
  /// the caller (an existing ACCEPTED conversation is exempt, as on send) => left out. Accounts the caller mutes are left
  /// out too. A caller past the blockedBy cap gets an empty list (fail closed). The reason chip is computed, never stored.
  /// limit 0 => 10, max 20 (clamped); negative => VALIDATION "limit". No pagination, by design (the ListSuggestedUsers
  /// precedent): one bounded call, no page token.
  /// Flags: "messaging" and "dm_suggestions" on for the caller (file comment). Rate limit: RATE_LIMIT_DM_SUGGESTIONS_PER_MIN
  /// 10/min/uid per instance; no daily cap. Answers under DEGRADED_MODE=readonly.
  /// Cost: at most 8 + 2 + 2 + 8 + 1 + 6 = 27 documents from the sources (inbox entries, plan memberships, plans,
  /// participant rows, community memberships, community members; the community doc is cached 60 s), then cache-first
  /// profile and follow-edge reads for at most 20 candidates (60 s caches). Writes nothing.
  Future<dzerothmessagingv1messaging.ListMessageSuggestionsResponse> listMessageSuggestions(
    dzerothmessagingv1messaging.ListMessageSuggestionsRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.MessagingService.listMessageSuggestions,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Store an MLS commit for an encrypted conversation and advance its epoch, or reset the group (file comment,
  /// "Ordering"). A commit changes the group (adds or removes devices, renews keys); it is a record, not a message.
  /// Flag: "messaging" on for the caller (per caller, as SendMessage's caller check; the peer's flag is not checked;
  /// FEATURE_DISABLED before any lookup); e2ee_dm is not needed.
  /// The caller needs a verified email (EMAIL_NOT_VERIFIED, before any lookup). Refused under DEGRADED_MODE=readonly.
  /// Answers, in this order (nothing is written on any refusal):
  /// 0. The per-minute bucket and the per-user daily call cap "messages_commits_daily" (below) are applied by the
  ///    interceptor before the service runs, before the flag, so a retry counts against them like any call.
  /// 1. After the flag and the verified email, before any lookup: idempotency_key format and conversation_id (32
  ///    lower-case hex), VALIDATION; the pair's form: mls_generation 1 to 2^63 - 2, and mls_epoch 1 to 2^63 - 1 unless
  ///    reset (VALIDATION "mls_generation" / "mls_epoch"). Then, still before any lookup, the per-(caller, conversation)
  ///    cap "messages_commits_per_conversation_daily" (every call, a reset included), then for a reset the reset cap
  ///    "messages_resets_daily": a malformed call burns neither; a retry and a call later refused count against both;
  ///    the per-conversation cap is keyed by the conversation id as sent, so it answers the same for an unknown
  ///    conversation, one the caller is not in and a real one.
  /// 2. Existing refusals: an unknown conversation or a non-participant => the one NOT_FOUND; a NONE conversation =>
  ///    VALIDATION "conversation_id" (start encryption with SendMessage mls_init); a conversation whose peer is gone, or
  ///    a block in either direction (the recipient's graph read in the transaction, as a send) => CANNOT_MESSAGE,
  ///    byte-identical to SendMessage's. Only these refuse: unlike SendMessage, a commit or reset is NOT refused because
  ///    the peer is not ACTIVE or has messaging off, by the peer's who-can-message policy, or because the conversation is
  ///    still a REQUEST (the request cap counts messages, not commits). The CANNOT_MESSAGE bytes are SendMessage's. What
  ///    bounds a commit into such a conversation is the per-conversation cap (20 a day per caller, above).
  /// 3. Retry recognition: a commit whose record for its pair (for a reset: (mls_generation + 1, 0)) already exists from
  ///    the same user with identical commit bytes is a retry: it returns the current pair (possibly later than
  ///    (generation, epoch + 1) by then) and writes nothing, before every check below. A record for that pair with other
  ///    bytes or from the other user is not a retry: the request goes on to 4 and 5 (at the latest STALE_EPOCH).
  /// 4. Field validation: commit 1-16384 bytes (VALIDATION "commit"); welcome at most 65536 bytes (VALIDATION
  ///    "welcome"); welcome and welcome_device_ids go together and the ids are 1-10, distinct, well-formed (VALIDATION
  ///    "welcome_device_ids"); a reset requires both (VALIDATION "welcome_device_ids"). Then the welcome-device
  ///    (active) check, which runs during the transaction, after the conversation read that names the peer (its
  ///    key-directory reads are not transactional): each device must be an
  ///    active registered device of the caller or the peer, and a reset must address at least one device of the PEER
  ///    (the caller's other devices are optional; the sending device creates the group and needs no welcome), else
  ///    VALIDATION "welcome_device_ids" without saying which.
  /// 5. The pair: STALE_EPOCH with the current pair.
  /// Normal commit: (mls_generation, mls_epoch) is the pair it is built on and must be the current pair; the commit
  /// record for that pair is created (the first accepted wins: a second commit on the same pair is STALE_EPOCH) and the
  /// conversation moves to (generation, epoch + 1).
  /// Reset (reset = true): used when a device cannot recover (see the file comment, "Catch-up"). mls_generation names
  /// the generation being REPLACED and mls_epoch is ignored; it must be the current generation, else STALE_EPOCH with
  /// the current pair (a device that knows nothing reads it from ListConversationCommits). The server creates the
  /// commit record (generation + 1, 0) and the welcomes of the fresh group, and the conversation moves to
  /// (generation + 1, 1). Two resets of the same generation: the first wins, the other is STALE_EPOCH. A reset SHOULD
  /// address every active key device of both users the resetter can obtain a key package for (its own other devices
  /// included). Every device shows "Encryption was reset". Limited per day (below).
  /// Welcomes: one per welcome_device_ids entry, stored for that device with the commit's pair, replacing that device's
  /// earlier welcome for this conversation (file comment, "Welcomes"), delivered by ListWelcomes, kept at least 30 days
  /// after creation and may be deleted at any time after that (deletion is not immediate; a client must not rely on an
  /// old welcome or commit having disappeared).
  /// Neither a commit nor a reset changes rev or any message, and no since_token is retired by them.
  /// Idempotency: the commit record's pair is the natural key (3. above); idempotency_key is format-checked only.
  /// Caps: RATE_LIMIT_MESSAGES_COMMIT_PER_MIN 20/min/uid per instance; daily caps per instance MESSAGES_COMMITS_PER_DAY
  /// 500 per user (metadata["limit"] = "messages_commits_daily"), MESSAGES_COMMITS_PER_CONVERSATION_PER_DAY 20 per
  /// caller and conversation ("messages_commits_per_conversation_daily") and MESSAGES_RESETS_PER_DAY 10 per user
  /// ("messages_resets_daily"); a reset counts against all three. Order in step 0 and 1 above. RATE_LIMITED, honour
  /// retry_after (the next IST day for a daily cap).
  /// Cost: one transaction reads the conversation (which names the peer for the device check), the recipient graph,
  /// the commit record (retry recognition) and at most 10 earlier welcomes = at most 13 reads; the device check runs
  /// during the transaction, after the conversation read, and adds at most 2 queries of at most 5 device documents
  /// through the key directory, whose reads are not transactional; at most 2 + 20 writes (the conversation's pair, the
  /// commit record, per device one welcome and the delete of the earlier one). Emits nothing; no push.
  Future<dzerothmessagingv1messaging.CommitConversationResponse> commitConversation(
    dzerothmessagingv1messaging.CommitConversationRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.MessagingService.commitConversation,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Commits of an encrypted conversation after a given pair, ascending by (generation, epoch), plus the conversation's
  /// current pair read fresh (never the instance cache). This is how a device catches up after STALE_EPOCH, on app
  /// open, and after joining through a welcome.
  /// The commits and the current pair are read in ONE consistent snapshot (a read-only transaction), so "no commit
  /// returned while the current pair is ahead" is a real gap, never a race between two reads.
  /// after_generation, after_epoch: the device's after-pair (file comment, "Catch-up"): the pair of the last commit it
  /// applied (a commit's pair is the one it was built on), exclusive. A device that joined through a Welcome passes the
  /// welcome's pair; the creator of the mls_init passes (1, 0), the creator of a reset of generation g passes
  /// (g + 1, 0). (0, 0) lists everything still stored.
  /// Follows on, for a device whose after-pair is (g, e), so whose own epoch is (g, e + 1): the next commit must be
  /// (g, e + 1) (built on the device's epoch), or (g + 1, 0) when generation g was ended by a reset (the device then
  /// joins generation g + 1 through its welcome, it never applies an epoch-0 record). A gap is: the first commit
  /// returned is anything else (the needed one was deleted: commits are kept at least 30 days, then may be deleted at any time), or no commit is returned
  /// while the returned current pair is not (g, e + 1). What the device does then (join from a welcome, wait to be
  /// added, or reset) is in the file comment, "Catch-up".
  /// more = true when a full page was read and at least one commit is returned: call again with the last returned
  /// commit's pair. The current pair can be ahead of the last commit returned while more is true.
  /// Flag: "messaging" not globally off (a user dropped from an allowlist can still read). Participant check and the one
  /// NOT_FOUND as ListMessages; a NONE conversation answers an empty list with the pair (0, 0). Validation:
  /// conversation_id; page_size as the file comment. Rate limit: RATE_LIMIT_MESSAGES_SYNC_PER_MIN 60/min/uid per
  /// instance, shared with ListEpochMessages, ListWelcomes and AckWelcomes.
  /// Cost: one read-only transaction: 1 conversation read + 1 query of at most page_size (max 50) commit records.
  /// Writes nothing.
  Future<dzerothmessagingv1messaging.ListConversationCommitsResponse> listConversationCommits(
    dzerothmessagingv1messaging.ListConversationCommitsRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.MessagingService.listConversationCommits,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Every message of one (generation, epoch) of an encrypted conversation, in message id order (not time order),
  /// paged with an opaque page_token. Once the epoch is closed (it has a commit, or a later generation exists after a
  /// reset; ListConversationCommits) no message can join it, so the full list is complete: a device calls this before
  /// applying the commit that ends an epoch, to prove it holds every message of the epoch (MLS deletes the epoch's
  /// keys on commit). It is a completeness set, not a decryption order: collect every page, then decrypt in created_at
  /// order, then by id (file comment, "Processing order"). Skip ids already processed.
  /// Messages at or before the caller's own DeleteConversation time (cleared_at in the response) ARE returned, unlike
  /// ListMessages, for completeness counting only: the client does not show or store them (it may decrypt and discard
  /// them; skipping their decryption would spend the forward limit). The tombstone rules are the same (DELETED_ACCOUNT
  /// and REMOVED carry no ciphertext), and a message whose ciphertext the retention sweep has removed has
  /// ciphertext_removed = true (30 days after created_at, possibly later: the sweep can lag).
  /// shared_post is never set (the post id is inside the ciphertext).
  /// page_token: sealed, bound to the caller, the conversation and the pair, expires after 30 days; an expired, foreign
  /// or tampered token, or one for another pair => VALIDATION "page_token": call again without it. next_page_token "" =>
  /// the end of the epoch's messages as of now.
  /// Flag: "messaging" not globally off. Participant check and the one NOT_FOUND as ListMessages (the conversation
  /// through the 60 s instance copy). Validation: conversation_id; mls_generation >= 1 and mls_epoch >= 1 (VALIDATION
  /// "mls_generation" / "mls_epoch"); page_size as the file comment. A NONE conversation or a pair with no messages is
  /// an empty list. Rate limit: RATE_LIMIT_MESSAGES_SYNC_PER_MIN (shared, see ListConversationCommits).
  /// Cost: at most 1 conversation read (cache-first) + 1 query of at most page_size (max 50) messages. Writes nothing.
  Future<dzerothmessagingv1messaging.ListEpochMessagesResponse> listEpochMessages(
    dzerothmessagingv1messaging.ListEpochMessagesRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.MessagingService.listEpochMessages,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Welcomes waiting for one of the caller's devices: how a device joins an encrypted conversation's group (after
  /// mls_init, a commit that adds it, or a reset). Process each, then AckWelcomes it; a welcome stays listed until
  /// acknowledged, replaced by a later welcome for the same conversation and device, or deleted after its retention: it
  /// is kept at least 30 days after creation and may be deleted at any time after that (deletion is not immediate; a
  /// client must not rely on an old welcome having disappeared). At most one per conversation per device (file comment,
  /// "Welcomes").
  /// There is no cursor: acknowledging is how the list advances. more = true when a full page was returned:
  /// acknowledge, then call again. Acknowledge also a welcome the device cannot use (it will not become usable), else
  /// it keeps its place on the page until it is deleted. A welcome whose mls_generation is below the conversation's
  /// current generation (ListConversationCommits) is useless: acknowledge it and wait for one of the current
  /// generation. Old-generation welcomes remain for devices a reset did not address. A welcome the device cannot process
  /// is acknowledged too and counts as no welcome (file comment, "Catch-up").
  /// Order: by welcome id (ids are hashes, so not time order). The server keeps at most one welcome per conversation
  /// per device, so a page holds at most one per conversation.
  /// device_id: [A-Za-z0-9_-]{16,64} and one of the caller's own registered devices (an inactive one included), else
  /// VALIDATION "device_id" (one answer for both). It is a filter, not an authentication (file comment, "Devices").
  /// Flag: "messaging" not globally off. Validation: device_id; page_size as the file comment. Rate limit:
  /// RATE_LIMIT_MESSAGES_SYNC_PER_MIN (shared, see ListConversationCommits).
  /// Cost: the device check (1 query of at most 5 device documents) + 1 query of at most page_size (max 10) welcomes.
  /// Writes nothing.
  Future<dzerothmessagingv1messaging.ListWelcomesResponse> listWelcomes(
    dzerothmessagingv1messaging.ListWelcomesRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.MessagingService.listWelcomes,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Delete welcomes the caller's device has processed. device_id as ListWelcomes (VALIDATION "device_id"); ids: 1-50
  /// welcome ids, each 32 lower-case hex, else VALIDATION "ids". Deletes by id among the caller's own welcomes:
  /// device_id does not further scope it (any of the caller's welcome ids is deleted), and ids that do not belong to
  /// the caller or are missing (already acknowledged, replaced, deleted after its retention, never existed) are ignored silently, so a
  /// replay is a success writing nothing new. Naturally idempotent; idempotency_key is format-checked only.
  /// Flag: "messaging" not globally off. Refused under DEGRADED_MODE=readonly. Rate limit:
  /// RATE_LIMIT_MESSAGES_SYNC_PER_MIN (shared, see ListConversationCommits).
  /// Cost: the device check (1 query of at most 5 device documents) + at most 50 deletes, no other read.
  Future<dzerothmessagingv1messaging.AckWelcomesResponse> ackWelcomes(
    dzerothmessagingv1messaging.AckWelcomesRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.MessagingService.ackWelcomes,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }
}
