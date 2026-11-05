//
//  Generated code. Do not modify.
//  source: dzeroth/graph/v1/graph.proto
//

import "package:connectrpc/connect.dart" as connect;
import "graph.pb.dart" as dzerothgraphv1graph;

abstract final class GraphService {
  /// Fully-qualified name of the GraphService service.
  static const name = 'dzeroth.graph.v1.GraphService';

  /// Follow a user, or ask to follow a protected one. Cap: 5,000 following (graph doc size). Rate limits: the graph
  /// follow bucket (30/min/uid per instance) and the in-memory graph_mutation_daily cap shared by every graph mutation
  /// (GRAPH_MUTATIONS_PER_DAY per uid per instance) => RESOURCE_EXHAUSTED + RATE_LIMITED, metadata["limit"] =
  /// "graph_mutation_daily".
  /// Transaction: caller graph read fresh, and the target's users doc read fresh too (so
  /// a Follow and a protect of the same account serialize and no Follow becomes an edge past a protect); the caller's
  /// users doc from the 60 s instance cache.
  /// Writes (edge): follows doc, caller graph, caller users counter, target users counter.
  /// Protected target the caller does not follow: Create followRequests/{caller}_{target}, add the target
  /// to the caller's requested[], returns REQUESTED; the target gets a follow_request notification,
  /// nobody gets a follow one. Replay (the request exists, or the target is in requested[]) => REQUESTED, writing nothing.
  /// 500 pending outgoing requests => FAILED_PRECONDITION + LIMIT_REACHED, metadata["limit"] =
  /// "follow_requests". A public target the caller still has a pending request to (the account went public and the
  /// job has not accepted it yet) => the edge, and the same transaction deletes the request and removes it from
  /// requested[].
  /// Errors: self => VALIDATION; target missing, not active, or blocked the caller => NOT_FOUND; caller blocks the
  /// target => FAILED_PRECONDITION + TARGET_BLOCKED (these three come before any request logic); at the cap =>
  /// LIMIT_REACHED. Replay (already following) => FOLLOWING, writing nothing, also before any
  /// request logic. Never gated by FEATURE_PRIVATE_ACCOUNTS.
  /// Notifications are events published after the commit, so this path does no Firestore work for them.
  /// user_id: [A-Za-z0-9-]{1,128}.
  static const follow = connect.Spec(
    '/$name/Follow',
    connect.StreamType.unary,
    dzerothgraphv1graph.FollowRequest.new,
    dzerothgraphv1graph.FollowResponse.new,
  );

  /// Unfollow. Blind batch: delete follows doc (Exists precondition) + caller graph following -= + 2 users counters.
  /// Not following => NONE, writing nothing (the precondition fails the whole batch). Any failed precondition is
  /// answered NONE, never a distinct code: by the invariant an ACTIVE caller's edge, following entry and
  /// both users docs exist together, so a failed batch means "not following".
  /// Withdraw: Unfollow also withdraws a pending follow request. When the edge batch fails its
  /// precondition, a second blind batch deletes followRequests/{caller}_{target} (Exists precondition) and removes the
  /// target from the caller's requested[]. A second failed precondition
  /// means there was nothing to withdraw: NONE, writing nothing. The target's follow_request notification row is not deleted.
  /// Never gated by FEATURE_PRIVATE_ACCOUNTS.
  /// user_id: [A-Za-z0-9-]{1,128}.
  static const unfollow = connect.Spec(
    '/$name/Unfollow',
    connect.StreamType.unary,
    dzerothgraphv1graph.UnfollowRequest.new,
    dzerothgraphv1graph.UnfollowResponse.new,
  );

  /// Incoming follow requests for the caller, newest first. Query: followRequests where followeeId ==
  /// caller ORDER BY createdAt DESC, Limit(page_size). Rows are hydrated through the identity directory; requesters who
  /// are not ACTIVE, whom the caller blocks or who block the caller are dropped, so a page may be short: keep following
  /// next_page_token while it is non-empty. Each row carries the caller's relationship to the requester (0 extra
  /// reads), and since is when the request was made.
  /// page_size 0 => 20, clamped to 1..50. page_token is opaque, bound to the caller, 24 h TTL; expired, foreign or
  /// tampered => INVALID_ARGUMENT + VALIDATION, metadata["field"] = "page_token", before any lookup.
  /// Flag: needs FEATURE_PRIVATE_ACCOUNTS (wire name "private_accounts") not globally off, or the caller
  /// to be protected now; else FAILED_PRECONDITION + FEATURE_DISABLED, metadata["feature"] = "private_accounts", 0
  /// reads beyond the account-status check. So with the flag globally off, a protected account can still manage its
  /// requests. Rate limit: the graph list bucket (20/min/uid per instance); no daily cap.
  static const listFollowRequests = connect.Spec(
    '/$name/ListFollowRequests',
    connect.StreamType.unary,
    dzerothgraphv1graph.ListFollowRequestsRequest.new,
    dzerothgraphv1graph.ListFollowRequestsResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Accept or decline the pending request from requester_user_id. One transaction reads the request and
  /// the requester's graph fresh; the requester's status comes from the identity directory, cache-first.
  /// Accept: Create follows/{requester}_{caller}; in the requester's graph following += caller and requested -= caller;
  /// followingCount +1 on the requester and followersCount +1 on the caller; the request is deleted. The requester
  /// gets a follow_accepted notification; the caller gets no follow notification.
  /// Decline: the request is deleted and requested -= caller in the requester's graph; nobody is notified.
  /// A requester who is no longer ACTIVE: the request is deleted and requested cleaned, success, no edge. A requester
  /// already following 5,000 accounts: FAILED_PRECONDITION + LIMIT_REACHED, metadata["limit"] =
  /// "requester_following", nothing written (decline still works).
  /// Replay (the request is gone: answered, withdrawn or never made) => success, writing nothing. The response always carries
  /// the caller's relationship to the requester. Idempotency is by natural key and state: idempotency_key is
  /// validated, not stored.
  /// Flag: as ListFollowRequests. Rate limit: RATE_LIMIT_FOLLOW_REQUESTS_RESPOND_PER_MIN, 60/min/uid per instance (at
  /// most 180/min with 3 instances); no daily cap (responses are bounded by the requests that exist).
  /// requester_user_id: [A-Za-z0-9-]{1,128}.
  static const respondToFollowRequest = connect.Spec(
    '/$name/RespondToFollowRequest',
    connect.StreamType.unary,
    dzerothgraphv1graph.RespondToFollowRequestRequest.new,
    dzerothgraphv1graph.RespondToFollowRequestResponse.new,
  );

  /// Block: removes follows in both directions (Unblock does not restore them).
  /// Transaction reads both graphs. Writes: caller graph (blocked +=, following -=), target graph
  /// (blockedBy +=, following -=) and, when edges existed, both users docs (counter decrements
  /// combined per doc) + follows deletes. Worst = mutual follow.
  /// Pending follow requests in either direction are deleted in the same transaction, and removed from
  /// both requested[] arrays in the graph writes it already makes.
  /// Cap: 2,000 blocked => LIMIT_REACHED. Shares the graph_mutation_daily cap (see Follow).
  /// Self => VALIDATION; unknown user => NOT_FOUND. Replay (already blocking) => blocking=true, writing nothing.
  static const block = connect.Spec(
    '/$name/Block',
    connect.StreamType.unary,
    dzerothgraphv1graph.BlockRequest.new,
    dzerothgraphv1graph.BlockResponse.new,
  );

  /// Removes the block on both sides (caller blocked -=, target blockedBy -=). Follows are not restored.
  /// Caller graph is read fresh; not blocking => writes nothing. No Firestore quota; shares the graph_mutation_daily cap (see Follow).
  static const unblock = connect.Spec(
    '/$name/Unblock',
    connect.StreamType.unary,
    dzerothgraphv1graph.UnblockRequest.new,
    dzerothgraphv1graph.UnblockResponse.new,
  );

  /// Mute hides the target's posts from the caller's timelines and notifications only; never visible to the target.
  /// Transaction reads caller graph, then the target's graph doc (existence only; its content, including who blocked
  /// whom, is never inspected); writes caller graph (muted +=).
  /// Cap: 2,000 muted => LIMIT_REACHED. Replay (already muting) => writes nothing.
  /// Target without an account => NOT_FOUND (same rule and response as Block), writing nothing.
  /// Muting a user who blocked the caller succeeds exactly as for a stranger.
  /// user_id: [A-Za-z0-9-]{1,128}.
  static const mute = connect.Spec(
    '/$name/Mute',
    connect.StreamType.unary,
    dzerothgraphv1graph.MuteRequest.new,
    dzerothgraphv1graph.MuteResponse.new,
  );

  /// Caller graph is read fresh; not muting => writes nothing. Shares the graph_mutation_daily cap (see Follow).
  static const unmute = connect.Spec(
    '/$name/Unmute',
    connect.StreamType.unary,
    dzerothgraphv1graph.UnmuteRequest.new,
    dzerothgraphv1graph.UnmuteResponse.new,
  );

  /// Caller's relationship to up to 50 users, computed from the caller's graph doc only (cached 60 s).
  /// Does not report whether the target follows the caller (that would need a lookup per user; GetProfileRelationship
  /// does, for one user).
  /// Never reflects blocks against the caller: a user who blocked the caller looks like a stranger (only the
  /// caller's own blocking/muting bits are reported). The caller's own id => NONE.
  static const getRelationships = connect.Spec(
    '/$name/GetRelationships',
    connect.StreamType.unary,
    dzerothgraphv1graph.GetRelationshipsRequest.new,
    dzerothgraphv1graph.GetRelationshipsResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// The caller's relationship to ONE user for a profile header, plus followed_by ("Follows you").
  /// relationship is exactly what GetRelationships computes from the caller's graph snapshot; followed_by is whether
  /// follows/{user_id}_{caller} exists. Single target by contract: there is no batch form, and list rows never carry
  /// followed_by (that would need a lookup per row). Clients call it instead of GetRelationships([user_id]) for the header.
  /// NOT_FOUND, byte-identical to GetProfile's missing-user error, when the target is missing or not ACTIVE, or has
  /// blocked the caller (the edge is then never read). The caller's own id => NONE and followed_by false, 0 extra
  /// reads. A caller who blocks the target gets blocking = true and followed_by = false (Block removed both edges).
  /// Staleness: the edge is cached 60 s per (caller, target) on the instance; this instance evicts the pair when the
  /// target follows or unfollows the caller and on a Block either way; other instances converge within 60 s.
  /// Flag: FEATURE_GRAPH, like every GraphService RPC. Rate limit: RATE_LIMIT_PROFILE_RELATIONSHIP_PER_MIN,
  /// 60/min/uid per instance (at most 180/min with 3 instances).
  /// The target's status comes from the identity directory, cache-first and usually warm from the header's GetProfile.
  /// user_id: [A-Za-z0-9-]{1,128}.
  static const getProfileRelationship = connect.Spec(
    '/$name/GetProfileRelationship',
    connect.StreamType.unary,
    dzerothgraphv1graph.GetProfileRelationshipRequest.new,
    dzerothgraphv1graph.GetProfileRelationshipResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// "Who to follow" for the caller: at most max_results users, no cursor, never a scan. Source
  /// (behind a server-side interface; clients must not assume it): friends of friends from one query over the
  /// follows of the caller's 30 newest followees (<= 30 edges), ranked by how many of them follow each candidate,
  /// ties broken by a per-day stable order; a curated server list fills in when the caller follows fewer than 3
  /// accounts or fewer than 3 candidates are found. Never returns the caller, anyone the caller follows or has
  /// requested, blocks, mutes, or is blocked by, or a user who is not ACTIVE. Each row carries relationship;
  /// since is unset. Results may change once a day per caller; the client caches them 24 h.
  /// Needs FEATURE_FOLLOW_SUGGESTIONS (wire name "follow_suggestions") on for the caller, and FEATURE_GRAPH; else
  /// FAILED_PRECONDITION + FEATURE_DISABLED, metadata["feature"] = "follow_suggestions", before any lookup.
  /// Rate limit: RATE_LIMIT_SUGGESTIONS_PER_MIN, 10/min/uid per instance (30/min with 3 instances); no daily cap.
  /// The result is cached per viewer on the instance for 1 h.
  static const listSuggestedUsers = connect.Spec(
    '/$name/ListSuggestedUsers',
    connect.StreamType.unary,
    dzerothgraphv1graph.ListSuggestedUsersRequest.new,
    dzerothgraphv1graph.ListSuggestedUsersResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Followers of a user, newest first. NOT_FOUND if the target is missing, not active, or blocked the caller.
  /// Rows for users the caller blocks or who blocked the caller are dropped (pages may be short; follow
  /// next_page_token). Each row carries the caller's relationship to that user.
  /// The target user and caller graph are cached 60 s; the page is a follows query limited to page_size, with the users
  /// hydrated in one batch.
  /// Protected account: a caller who is neither the account nor a follower of it gets
  /// FAILED_PRECONDITION + PROTECTED_ACCOUNT after the target and caller graph lookups, before any page read.
  /// The NOT_FOUND rules above come first.
  /// Rate limits: the graph list bucket (20/min/uid per instance) and the in-memory follow_list_daily cap shared with
  /// ListFollowing (FOLLOW_LIST_CALLS_PER_DAY per uid per instance) => RESOURCE_EXHAUSTED + RATE_LIMITED,
  /// metadata["limit"] = "follow_list_daily".
  static const listFollowers = connect.Spec(
    '/$name/ListFollowers',
    connect.StreamType.unary,
    dzerothgraphv1graph.ListFollowersRequest.new,
    dzerothgraphv1graph.ListFollowersResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Accounts a user follows, newest first. Same visibility (the PROTECTED_ACCOUNT rule included), row filtering and
  /// paging and rate limits as ListFollowers (the follow_list_daily cap is shared).
  static const listFollowing = connect.Spec(
    '/$name/ListFollowing',
    connect.StreamType.unary,
    dzerothgraphv1graph.ListFollowingRequest.new,
    dzerothgraphv1graph.ListFollowingResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Caller's blocked accounts (from graph doc, newest first) hydrated with GetAll users (cached 60 s).
  /// Users who blocked the caller, and missing or inactive users, are omitted.
  /// A page that finds a uid with no users doc removes that stale entry (one ArrayRemove of at most 50 ids).
  static const listBlockedUsers = connect.Spec(
    '/$name/ListBlockedUsers',
    connect.StreamType.unary,
    dzerothgraphv1graph.ListBlockedUsersRequest.new,
    dzerothgraphv1graph.ListBlockedUsersResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Caller's muted accounts (from graph doc, newest first) hydrated with GetAll users (cached 60 s).
  /// Users who blocked the caller, and missing or inactive users, are omitted.
  /// A page that finds a uid with no users doc removes that stale entry (one ArrayRemove of at most 50 ids).
  static const listMutedUsers = connect.Spec(
    '/$name/ListMutedUsers',
    connect.StreamType.unary,
    dzerothgraphv1graph.ListMutedUsersRequest.new,
    dzerothgraphv1graph.ListMutedUsersResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );
}
