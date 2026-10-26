//
//  Generated code. Do not modify.
//  source: dzeroth/graph/v1/graph.proto
//

import "package:connectrpc/connect.dart" as connect;
import "graph.pb.dart" as dzerothgraphv1graph;
import "graph.connect.spec.dart" as specs;

extension type GraphServiceClient (connect.Transport _transport) {
  /// Follow a public user. Quota: 200 follows/day (50 for accounts < 24 h). Cap: 5,000 following (graph doc size).
  /// Transaction: caller graph + quotas/{uid} read fresh; target and caller users docs from the 60 s instance cache.
  /// Writes: follows doc, caller graph, caller users counter, target users counter, quotas.
  /// Errors: self => VALIDATION; target missing, not active, or blocked the caller => NOT_FOUND; caller blocks the
  /// target => FAILED_PRECONDITION + TARGET_BLOCKED; private target (legacy data) => FEATURE_DISABLED; at the cap =>
  /// LIMIT_REACHED; over quota => QUOTA_EXCEEDED. Replay (already following) => FOLLOWING, 0 writes.
  /// No notification write in this slice (the notifications plan adds its own budget).
  /// Firestore: reads 4 cold / 2 warm (+1 if the caller's blockedBy overflowed, ADR-0008 D2), writes 5; replay reads
  /// 4 cold / 2 warm, writes 0 (cold = the identity profile cache misses, which a preceding Follow's eviction makes
  /// the norm; ADR-0008 A2, planning value 4). user_id: [A-Za-z0-9-]{1,128}.
  Future<dzerothgraphv1graph.FollowResponse> follow(
    dzerothgraphv1graph.FollowRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.GraphService.follow,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Unfollow. Blind batch: delete follows doc (Exists precondition) + caller graph following -= + 2 users counters.
  /// Not following => NONE with 0 writes (the precondition fails the whole batch). Any failed precondition is
  /// answered NONE, never a distinct code: by the ADR-0009 invariant an ACTIVE caller's edge, following entry and
  /// both users docs exist together, so a failed batch means "not following".
  /// Firestore: the batch reads 0, writes 3 (0 on no-op), deletes 1; the request logs 1 read (the caller's profile
  /// read by the account-status check, cold after a preceding Follow; ADR-0008 Amendment 2026-09-30 (2)).
  /// user_id: [A-Za-z0-9-]{1,128}.
  Future<dzerothgraphv1graph.UnfollowResponse> unfollow(
    dzerothgraphv1graph.UnfollowRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.GraphService.unfollow,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Incoming follow requests for the caller (private accounts).
  /// Until private accounts ship (ADR-0008 D1): always FAILED_PRECONDITION + ERROR_REASON_FEATURE_DISABLED.
  /// Firestore: reads 0/0, writes 0 (planned when enabled: reads 100/5, page + hydration, users cached 60 s).
  Future<dzerothgraphv1graph.ListFollowRequestsResponse> listFollowRequests(
    dzerothgraphv1graph.ListFollowRequestsRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.GraphService.listFollowRequests,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Accept or decline an incoming request. Replay: request doc already gone => returns current state.
  /// Until private accounts ship (ADR-0008 D1): always FAILED_PRECONDITION + ERROR_REASON_FEATURE_DISABLED.
  /// Planned: delete request, create follows, requester graph (following += , requested -=), 2 users counters.
  /// Firestore: reads 0/0, writes 0 (planned when enabled: reads 1/1, writes 4/4, deletes 1/1).
  Future<dzerothgraphv1graph.RespondToFollowRequestResponse> respondToFollowRequest(
    dzerothgraphv1graph.RespondToFollowRequestRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.GraphService.respondToFollowRequest,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Block: removes follows in both directions (Unblock does not restore them).
  /// Transaction reads both graphs + quotas/{uid}. Writes: caller graph (blocked +=, following -=), target graph
  /// (blockedBy +=, following -=), quotas (blocks) and, when edges existed, both users docs (counter decrements
  /// combined per doc) + follows deletes. Worst = mutual follow.
  /// Quota: 200 blocks+mutes/day (50 for accounts < 24 h). Cap: 2,000 blocked => LIMIT_REACHED.
  /// Self => VALIDATION; unknown user => NOT_FOUND. Replay (already blocking) => blocking=true, 0 writes.
  /// Firestore: reads 3/3, writes 5/3, deletes 2/0.
  Future<dzerothgraphv1graph.BlockResponse> block(
    dzerothgraphv1graph.BlockRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.GraphService.block,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Removes the block on both sides (caller blocked -=, target blockedBy -=). Follows are not restored.
  /// Caller graph is read fresh; not blocking => 0 writes. Never quota-gated.
  /// Firestore: reads 1/1, writes 2/2 (0 on no-op).
  Future<dzerothgraphv1graph.UnblockResponse> unblock(
    dzerothgraphv1graph.UnblockRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.GraphService.unblock,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Mute hides the target's posts from the caller's timelines and notifications only; never visible to the target.
  /// Transaction reads caller graph, then the target's graph doc (existence only; its content, including who blocked
  /// whom, is never inspected), then quotas/{uid}; writes caller graph (muted +=) + quotas (blocks).
  /// Quota: shared with Block. Cap: 2,000 muted => LIMIT_REACHED. Replay (already muting) => 0 writes.
  /// Target without an account => NOT_FOUND (same rule and response as Block; ADR-0008 A1), 0 writes, no quota used.
  /// Muting a user who blocked the caller succeeds exactly as for a stranger.
  /// Firestore: reads 3, writes 2 (0 on replay); NOT_FOUND reads 2. user_id: [A-Za-z0-9-]{1,128}.
  Future<dzerothgraphv1graph.MuteResponse> mute(
    dzerothgraphv1graph.MuteRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.GraphService.mute,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Caller graph is read fresh; not muting => 0 writes. Never quota-gated.
  /// Firestore: reads 1/1, writes 1/1 (0 on no-op).
  Future<dzerothgraphv1graph.UnmuteResponse> unmute(
    dzerothgraphv1graph.UnmuteRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.GraphService.unmute,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Caller's relationship to up to 50 users, computed from the caller's graph doc only (1 read, cached 60 s).
  /// Does not report whether the target follows the caller (that would cost 1 read per user; GetProfileRelationship
  /// does, for one user).
  /// Never reflects blocks against the caller: a user who blocked the caller looks like a stranger (only the
  /// caller's own blocking/muting bits are reported). The caller's own id => NONE.
  /// Firestore: reads 1/0.5 (graph cached 60 s), writes 0.
  Future<dzerothgraphv1graph.GetRelationshipsResponse> getRelationships(
    dzerothgraphv1graph.GetRelationshipsRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.GraphService.getRelationships,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// The caller's relationship to ONE user for a profile header, plus followed_by ("Follows you", ADR-0024 D7).
  /// relationship is exactly what GetRelationships computes from the caller's graph snapshot; followed_by is whether
  /// follows/{user_id}_{caller} exists. Single target by contract: there is no batch form, and list rows never carry
  /// followed_by (1 read per row). Clients call it instead of GetRelationships([user_id]) for the header.
  /// NOT_FOUND, byte-identical to GetProfile's missing-user error, when the target is missing or not ACTIVE, or has
  /// blocked the caller (the edge is then never read). The caller's own id => NONE and followed_by false, 0 extra
  /// reads. A caller who blocks the target gets blocking = true and followed_by = false (Block removed both edges).
  /// Staleness: the edge is cached 60 s per (caller, target) on the instance; this instance evicts the pair when the
  /// target follows or unfollows the caller and on a Block either way; other instances converge within 60 s.
  /// Flag: FEATURE_GRAPH, like every GraphService RPC. Rate limit: RATE_LIMIT_PROFILE_RELATIONSHIP_PER_MIN,
  /// 60/min/uid per instance (at most 180/min with 3 instances). Charged to the per-uid daily read budget.
  /// Firestore: reads 3 cold (interceptor, caller graph, edge doc; +1 if the caller's blockedBy overflowed,
  /// ADR-0008 D2; the target's status comes from the identity directory, cache-first and usually warm from the
  /// header's GetProfile) / 0 warm, planning 1; writes 0. user_id: [A-Za-z0-9-]{1,128}.
  Future<dzerothgraphv1graph.GetProfileRelationshipResponse> getProfileRelationship(
    dzerothgraphv1graph.GetProfileRelationshipRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.GraphService.getProfileRelationship,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// "Who to follow" for the caller (ADR-0024 D8): at most max_results users, no cursor, never a scan. Source
  /// (behind a server-side interface; clients must not assume it): friends of friends from one query over the
  /// follows of the caller's 30 newest followees (<= 30 edges), ranked by how many of them follow each candidate,
  /// ties broken by a per-day stable order; a curated server list fills in when the caller follows fewer than 3
  /// accounts or fewer than 3 candidates are found. Never returns the caller, anyone the caller follows or has
  /// requested, blocks, mutes, or is blocked by, or a user who is not ACTIVE. Each row carries relationship;
  /// since is unset. Results may change once a day per caller; the client caches them 24 h.
  /// Needs FEATURE_FOLLOW_SUGGESTIONS (wire name "follow_suggestions") on for the caller, and FEATURE_GRAPH; else
  /// FAILED_PRECONDITION + FEATURE_DISABLED, metadata["feature"] = "follow_suggestions", 0 reads.
  /// Rate limits: RATE_LIMIT_SUGGESTIONS_PER_MIN, 10/min/uid per instance (30/min with 3 instances), and
  /// SUGGESTIONS_CALLS_PER_DAY, 50 calls/uid/IST day per instance (150 with 3) => RATE_LIMITED,
  /// metadata["limit"] = "suggestions_daily". Charged to the per-uid daily read budget (ADR-0010 D5).
  /// Firestore: hard cap 42 reads cold (interceptor 1, caller graph 1, follows edges <= 30, user hydration <= 10),
  /// 12 on the curated path (1 + 1 + 10); warm (per-viewer instance cache, 1 h) 1, the interceptor; planning 25.
  /// Writes 0.
  Future<dzerothgraphv1graph.ListSuggestedUsersResponse> listSuggestedUsers(
    dzerothgraphv1graph.ListSuggestedUsersRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.GraphService.listSuggestedUsers,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Followers of a user, newest first. NOT_FOUND if the target is missing, not active, or blocked the caller.
  /// Rows for users the caller blocks or who blocked the caller are dropped (pages may be short; follow
  /// next_page_token). Each row carries the caller's relationship to that user (0 extra reads).
  /// Reads: target user + caller graph (both cached 60 s) + follows page (Limit page_size) + GetAll users hydration.
  /// Firestore: reads 102/30, writes 0.
  Future<dzerothgraphv1graph.ListFollowersResponse> listFollowers(
    dzerothgraphv1graph.ListFollowersRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.GraphService.listFollowers,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Accounts a user follows, newest first. Same visibility, row filtering and cost shape as ListFollowers.
  /// Firestore: reads 102/30, writes 0.
  Future<dzerothgraphv1graph.ListFollowingResponse> listFollowing(
    dzerothgraphv1graph.ListFollowingRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.GraphService.listFollowing,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Caller's blocked accounts (from graph doc, newest first) hydrated with GetAll users (cached 60 s).
  /// Users who blocked the caller, and missing or inactive users, are omitted (ADR-0008 D9).
  /// Firestore: reads 51/10, writes 0, plus at most +1 write (one ArrayRemove of at most 50 ids, T27) on a page
  /// that finds a uid with no users doc, once per stale entry.
  Future<dzerothgraphv1graph.ListBlockedUsersResponse> listBlockedUsers(
    dzerothgraphv1graph.ListBlockedUsersRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.GraphService.listBlockedUsers,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Caller's muted accounts (from graph doc, newest first) hydrated with GetAll users (cached 60 s).
  /// Users who blocked the caller, and missing or inactive users, are omitted (ADR-0008 D9).
  /// Firestore: reads 51/10, writes 0, plus at most +1 write (one ArrayRemove of at most 50 ids, T27) on a page
  /// that finds a uid with no users doc, once per stale entry.
  Future<dzerothgraphv1graph.ListMutedUsersResponse> listMutedUsers(
    dzerothgraphv1graph.ListMutedUsersRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.GraphService.listMutedUsers,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }
}
