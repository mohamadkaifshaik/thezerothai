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
  /// Idempotency (the bend of rules 1 and 4): the message id is derived from (caller,
  /// idempotency_key) and Created in the send transaction, so a retry returns the stored message and writes nothing; the
  /// same key with a different body => VALIDATION "idempotency_key". Clients dedupe by message id.
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
}
