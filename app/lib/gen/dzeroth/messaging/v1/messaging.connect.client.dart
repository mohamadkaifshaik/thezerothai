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
  /// (VALIDATION "text", 0 reads).
  /// Flag: per caller AND per recipient. Caller off => FEATURE_DISABLED; recipient off => CANNOT_MESSAGE.
  /// Refusals, all CANNOT_MESSAGE with identical bytes: either side blocks the other (the caller and recipient graph
  /// snapshots, cached 60 s, so a new Block applies at once on its instance and within 60 s elsewhere; ADR-0027 A8),
  /// the recipient is not ACTIVE or has messaging off, the conversation is gone (the peer deleted the account).
  /// Routing: a new conversation is ACCEPTED when the two follow each other, else REQUEST (the recipient's entry goes
  /// to REQUESTS). While REQUEST, the requester may send MESSAGES_REQUEST_MAX_UNANSWERED (3) messages, then
  /// LIMIT_REACHED "request_unanswered"; a message from the recipient of the request accepts it (as on X). The
  /// recipient muted the caller => delivered silently (no unread increment, no push).
  /// Idempotency (ADR-0027 D2, the ADR-0021 bend of rules 1 and 4): the message id is derived from (caller,
  /// idempotency_key) and Created in the send transaction, so a retry returns the stored message with 0 writes; the
  /// same key with a different body => VALIDATION "idempotency_key". Clients dedupe by message id.
  /// Caps (ADR-0027 D13): RATE_LIMIT_MESSAGES_SEND_PER_MIN 20/min/uid per instance (60/min at 3 instances);
  /// MESSAGES_SENDS_PER_DAY 300 (50 for new accounts) per instance (<= 900/day at 3) => RATE_LIMITED metadata["limit"]
  /// = "messages_daily"; QUOTA_DM_NEW_CONVERSATIONS_PER_DAY 20 new conversations per IST day (5 for new accounts),
  /// exact (quotas/{uid}.dmNew, in the transaction) => LIMIT_REACHED "dm_new_daily"; MESSAGES_REQUEST_MAX_UNANSWERED 3,
  /// exact (conversations.requestCount, in the transaction).
  /// Push: after the commit one `message` event through notifications.Emitter (one Pub/Sub publish, 0 Firestore on
  /// this path), only when the recipient's side is accepted and not silent; a request never pushes. The push is
  /// generic ("New message") and carries only the conversation id (NOTIFICATION_TYPE_MESSAGE).
  /// Firestore (ADR-0027 Cost impact): accepted conversation reads 5 worst cold (interceptor, caller graph, recipient
  /// graph, recipient users via the directory, conversation doc in the transaction), planning 2.5; writes 3 (message,
  /// 2 entries), 4 while REQUEST (+ requestCount). New conversation reads 7 worst (+ fresh recipient status, quotas),
  /// writes 5 (message, conversation, 2 entries, quotas.dmNew). Replay +1 read (the stored message), 0 writes.
  /// Refused <= 5 reads, 0 writes; a validation rejection 0 reads. Deletes 0.
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
  /// blocks the caller; INBOX keeps every entry, with can_reply = false when either side blocks. Filtering runs after
  /// the page query, so a page may be short or empty while next_page_token is non-empty: keep following it.
  /// request_count is set on every INBOX first page and since refresh (an empty refresh included); 0 on an older page and
  /// on REQUESTS. Clients treat the INBOX value as authoritative, 0 included (W7-37).
  /// There is no gap_page_token here (plan W7-2): a since refresh returns at most page_size entries.
  /// Flag: not globally off. Rate limit: RATE_LIMIT_MESSAGES_READ_PER_MIN 30/min/uid per instance (90/min at 3),
  /// shared with ListMessages.
  /// Firestore: first INBOX page 20: reads 23 worst cold (interceptor, query 20, caller graph, requests count()),
  /// planning 9; REQUESTS the same without the count(). INBOX since refresh reads 4 worst (interceptor, query min 1, caller
  /// graph, requests count()), planning 3; an empty one 3. Writes 0.
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
  /// Client polling (ADR-0027 D7): only on a visible thread; web 15 s while hot, Android 30 s while hot, 45 s while
  /// quiet, stopped after 5 min idle or when hidden; a push for the conversation triggers an immediate pull; a
  /// RATE_LIMITED answer pauses polling.
  /// Flag: not globally off. Rate limit: RATE_LIMIT_MESSAGES_READ_PER_MIN 30/min/uid per instance (90/min at 3),
  /// shared with ListConversations.
  /// Firestore: first page 20 / 50: reads 25 / 55 worst cold (interceptor, conversation, query, peer users, caller
  /// graph for can_reply, the caller's entry), planning 16; older page 24 / 54 (no entry), planning 15. since poll:
  /// reads 3 cold (interceptor, conversation, query min 1) + 1 per new message returned, planning 1.2. NOT_FOUND after <= 2 reads. Writes 0.
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
  /// update with an Exists precondition). The read time is never shown to the peer (no read receipts, F4). A missing
  /// entry (unknown id, non-participant, deleted for the caller) => success, 0 writes. Evicts the caller's
  /// unread_conversation_count cache on this instance. Call only when the client holds unread_count > 0.
  /// Flag: not globally off. Refused under DEGRADED_MODE=readonly.
  /// Firestore: reads 1 (interceptor), planning 0.3; writes 1 (0 when the entry is missing); deletes 0.
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
  /// NOT_FOUND. Already accepted => success, 0 writes. Emits nothing.
  /// Flag: per caller AND per recipient (the peer); peer off => CANNOT_MESSAGE. Refused under DEGRADED_MODE=readonly.
  /// Firestore: reads 4 worst (interceptor, conversation, request entry, the requester's entry), planning 3.5; writes 3
  /// (conversation state, dmInbox entry, the requester's entry: request flag cleared, changedAt moved; 2 when the requester
  /// deleted that entry); deletes 1 (dmRequests entry).
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
  /// Firestore: reads 3 worst, planning 2.5; writes 1 (clearedAt on the conversation); deletes 1 (the caller's entry).
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
