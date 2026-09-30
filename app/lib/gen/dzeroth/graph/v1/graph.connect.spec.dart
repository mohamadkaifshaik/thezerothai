//
//  Generated code. Do not modify.
//  source: dzeroth/graph/v1/graph.proto
//

import "package:connectrpc/connect.dart" as connect;
import "graph.pb.dart" as dzerothgraphv1graph;

abstract final class GraphService {
  /// Fully-qualified name of the GraphService service.
  static const name = 'dzeroth.graph.v1.GraphService';

  /// Follow a public user. Quota: 200 follows/day (50 for accounts < 24 h). Cap: 5,000 following (graph doc size).
  /// Transaction: caller graph + quotas/{uid} read fresh; target and caller users docs from the 60 s instance cache.
  /// Writes: follows doc, caller graph, caller users counter, target users counter, quotas.
  /// Errors: self => VALIDATION; target missing, not active, or blocked the caller => NOT_FOUND; caller blocks the
  /// target => FAILED_PRECONDITION + TARGET_BLOCKED; private target (legacy data) => FEATURE_DISABLED; at the cap =>
  /// LIMIT_REACHED; over quota => QUOTA_EXCEEDED. Replay (already following) => FOLLOWING, 0 writes.
  /// No notification write in this slice (the notifications plan adds its own budget).
  /// Firestore: reads 4/2 (+1 if the caller's blockedBy overflowed, ADR-0008 D2), writes 5/5; replay reads 2/2, writes 0.
  static const follow = connect.Spec(
    '/$name/Follow',
    connect.StreamType.unary,
    dzerothgraphv1graph.FollowRequest.new,
    dzerothgraphv1graph.FollowResponse.new,
  );

  /// Unfollow. Blind batch: delete follows doc (Exists precondition) + caller graph following -= + 2 users counters.
  /// Not following => NONE with 0 writes (the precondition fails the whole batch).
  /// Firestore: reads 0/0, writes 3/3 (0 on no-op), deletes 1/1.
  static const unfollow = connect.Spec(
    '/$name/Unfollow',
    connect.StreamType.unary,
    dzerothgraphv1graph.UnfollowRequest.new,
    dzerothgraphv1graph.UnfollowResponse.new,
  );

  /// Incoming follow requests for the caller (private accounts).
  /// Until private accounts ship (ADR-0008 D1): always FAILED_PRECONDITION + ERROR_REASON_FEATURE_DISABLED.
  /// Firestore: reads 0/0, writes 0 (planned when enabled: reads 100/5, page + hydration, users cached 60 s).
  static const listFollowRequests = connect.Spec(
    '/$name/ListFollowRequests',
    connect.StreamType.unary,
    dzerothgraphv1graph.ListFollowRequestsRequest.new,
    dzerothgraphv1graph.ListFollowRequestsResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Accept or decline an incoming request. Replay: request doc already gone => returns current state.
  /// Until private accounts ship (ADR-0008 D1): always FAILED_PRECONDITION + ERROR_REASON_FEATURE_DISABLED.
  /// Planned: delete request, create follows, requester graph (following += , requested -=), 2 users counters.
  /// Firestore: reads 0/0, writes 0 (planned when enabled: reads 1/1, writes 4/4, deletes 1/1).
  static const respondToFollowRequest = connect.Spec(
    '/$name/RespondToFollowRequest',
    connect.StreamType.unary,
    dzerothgraphv1graph.RespondToFollowRequestRequest.new,
    dzerothgraphv1graph.RespondToFollowRequestResponse.new,
  );

  /// Block: removes follows in both directions (Unblock does not restore them).
  /// Transaction reads both graphs + quotas/{uid}. Writes: caller graph (blocked +=, following -=), target graph
  /// (blockedBy +=, following -=), quotas (blocks) and, when edges existed, both users docs (counter decrements
  /// combined per doc) + follows deletes. Worst = mutual follow.
  /// Quota: 200 blocks+mutes/day (50 for accounts < 24 h). Cap: 2,000 blocked => LIMIT_REACHED.
  /// Self => VALIDATION; unknown user => NOT_FOUND. Replay (already blocking) => blocking=true, 0 writes.
  /// Firestore: reads 3/3, writes 5/3, deletes 2/0.
  static const block = connect.Spec(
    '/$name/Block',
    connect.StreamType.unary,
    dzerothgraphv1graph.BlockRequest.new,
    dzerothgraphv1graph.BlockResponse.new,
  );

  /// Removes the block on both sides (caller blocked -=, target blockedBy -=). Follows are not restored.
  /// Caller graph is read fresh; not blocking => 0 writes. Never quota-gated.
  /// Firestore: reads 1/1, writes 2/2 (0 on no-op).
  static const unblock = connect.Spec(
    '/$name/Unblock',
    connect.StreamType.unary,
    dzerothgraphv1graph.UnblockRequest.new,
    dzerothgraphv1graph.UnblockResponse.new,
  );

  /// Mute hides the target's posts from the caller's timelines and notifications only; never visible to the target.
  /// Transaction reads caller graph + quotas/{uid}; writes caller graph (muted +=) + quotas (blocks).
  /// Quota: shared with Block. Cap: 2,000 muted => LIMIT_REACHED. Replay (already muting) => 0 writes.
  /// Firestore: reads 2/2, writes 2/2 (0 on replay).
  static const mute = connect.Spec(
    '/$name/Mute',
    connect.StreamType.unary,
    dzerothgraphv1graph.MuteRequest.new,
    dzerothgraphv1graph.MuteResponse.new,
  );

  /// Caller graph is read fresh; not muting => 0 writes. Never quota-gated.
  /// Firestore: reads 1/1, writes 1/1 (0 on no-op).
  static const unmute = connect.Spec(
    '/$name/Unmute',
    connect.StreamType.unary,
    dzerothgraphv1graph.UnmuteRequest.new,
    dzerothgraphv1graph.UnmuteResponse.new,
  );

  /// Caller's relationship to up to 50 users, computed from the caller's graph doc only (1 read, cached 60 s).
  /// Does not report whether the target follows the caller (that would cost 1 read per user).
  /// Never reflects blocks against the caller: a user who blocked the caller looks like a stranger (only the
  /// caller's own blocking/muting bits are reported). The caller's own id => NONE.
  /// Firestore: reads 1/0.5 (graph cached 60 s), writes 0.
  static const getRelationships = connect.Spec(
    '/$name/GetRelationships',
    connect.StreamType.unary,
    dzerothgraphv1graph.GetRelationshipsRequest.new,
    dzerothgraphv1graph.GetRelationshipsResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Followers of a user, newest first. NOT_FOUND if the target is missing, not active, or blocked the caller.
  /// Rows for users the caller blocks or who blocked the caller are dropped (pages may be short; follow
  /// next_page_token). Each row carries the caller's relationship to that user (0 extra reads).
  /// Reads: target user + caller graph (both cached 60 s) + follows page (Limit page_size) + GetAll users hydration.
  /// Firestore: reads 102/30, writes 0.
  static const listFollowers = connect.Spec(
    '/$name/ListFollowers',
    connect.StreamType.unary,
    dzerothgraphv1graph.ListFollowersRequest.new,
    dzerothgraphv1graph.ListFollowersResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Accounts a user follows, newest first. Same visibility, row filtering and cost shape as ListFollowers.
  /// Firestore: reads 102/30, writes 0.
  static const listFollowing = connect.Spec(
    '/$name/ListFollowing',
    connect.StreamType.unary,
    dzerothgraphv1graph.ListFollowingRequest.new,
    dzerothgraphv1graph.ListFollowingResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Caller's blocked accounts (from graph doc, newest first) hydrated with GetAll users (cached 60 s).
  /// Users who blocked the caller, and missing or inactive users, are omitted (ADR-0008 D9).
  /// Firestore: reads 51/10, writes 0, plus at most +1 write (one ArrayRemove of at most 50 ids, T27) on a page
  /// that finds a uid with no users doc, once per stale entry.
  static const listBlockedUsers = connect.Spec(
    '/$name/ListBlockedUsers',
    connect.StreamType.unary,
    dzerothgraphv1graph.ListBlockedUsersRequest.new,
    dzerothgraphv1graph.ListBlockedUsersResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Caller's muted accounts (from graph doc, newest first) hydrated with GetAll users (cached 60 s).
  /// Users who blocked the caller, and missing or inactive users, are omitted (ADR-0008 D9).
  /// Firestore: reads 51/10, writes 0, plus at most +1 write (one ArrayRemove of at most 50 ids, T27) on a page
  /// that finds a uid with no users doc, once per stale entry.
  static const listMutedUsers = connect.Spec(
    '/$name/ListMutedUsers',
    connect.StreamType.unary,
    dzerothgraphv1graph.ListMutedUsersRequest.new,
    dzerothgraphv1graph.ListMutedUsersResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );
}
