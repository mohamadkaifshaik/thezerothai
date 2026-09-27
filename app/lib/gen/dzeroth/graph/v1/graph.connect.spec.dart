//
//  Generated code. Do not modify.
//  source: dzeroth/graph/v1/graph.proto
//

import "package:connectrpc/connect.dart" as connect;
import "graph.pb.dart" as dzerothgraphv1graph;

abstract final class GraphService {
  /// Fully-qualified name of the GraphService service.
  static const name = 'dzeroth.graph.v1.GraphService';

  /// Follow a user; for private accounts creates a follow request instead. Quota: 200 follows/day.
  /// Cap: 5,000 following (graph doc size). Reads: caller graph (cached), target user (cached), target graph
  /// (blocked-by + privacy), quotas/{uid}. Writes: follows doc, caller graph, caller users counter, target users
  /// counter, quotas. Private target: followRequests doc + caller graph.requested + quotas.
  /// Async: 1 notification write (notifications module).
  /// Firestore: reads 4/2, writes 5/5 (+1 async).
  static const follow = connect.Spec(
    '/$name/Follow',
    connect.StreamType.unary,
    dzerothgraphv1graph.FollowRequest.new,
    dzerothgraphv1graph.FollowResponse.new,
  );

  /// Unfollow or cancel a pending request. No-op if not following (per cached graph re-checked in the batch precondition).
  /// Firestore: reads 1/0, writes 3/3, deletes 1/1.
  static const unfollow = connect.Spec(
    '/$name/Unfollow',
    connect.StreamType.unary,
    dzerothgraphv1graph.UnfollowRequest.new,
    dzerothgraphv1graph.UnfollowResponse.new,
  );

  /// Incoming follow requests for the caller (private accounts). Hydrated with a batched GetAll of users.
  /// Firestore: reads 100/5 (page + hydration, users cached 60 s), writes 0.
  static const listFollowRequests = connect.Spec(
    '/$name/ListFollowRequests',
    connect.StreamType.unary,
    dzerothgraphv1graph.ListFollowRequestsRequest.new,
    dzerothgraphv1graph.ListFollowRequestsResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Accept or decline an incoming request. Replay: request doc already gone => returns current state.
  /// Accept: delete request, create follows, requester graph (following += , requested -=), 2 users counters.
  /// Firestore: reads 1/1, writes 4/4, deletes 1/1.
  static const respondToFollowRequest = connect.Spec(
    '/$name/RespondToFollowRequest',
    connect.StreamType.unary,
    dzerothgraphv1graph.RespondToFollowRequestRequest.new,
    dzerothgraphv1graph.RespondToFollowRequestResponse.new,
  );

  /// Block: also removes follows in both directions. Idempotent (ArrayUnion).
  /// Worst (mutual follow): caller graph, target graph, both users docs + 2 follows deletes.
  /// Firestore: reads 2/1, writes 4/1, deletes 2/0.
  static const block = connect.Spec(
    '/$name/Block',
    connect.StreamType.unary,
    dzerothgraphv1graph.BlockRequest.new,
    dzerothgraphv1graph.BlockResponse.new,
  );

  /// Firestore: reads 0/0, writes 1/1.
  static const unblock = connect.Spec(
    '/$name/Unblock',
    connect.StreamType.unary,
    dzerothgraphv1graph.UnblockRequest.new,
    dzerothgraphv1graph.UnblockResponse.new,
  );

  /// Mute hides the target's posts from the caller's timelines only. Idempotent (ArrayUnion).
  /// Firestore: reads 0/0, writes 1/1.
  static const mute = connect.Spec(
    '/$name/Mute',
    connect.StreamType.unary,
    dzerothgraphv1graph.MuteRequest.new,
    dzerothgraphv1graph.MuteResponse.new,
  );

  /// Firestore: reads 0/0, writes 1/1.
  static const unmute = connect.Spec(
    '/$name/Unmute',
    connect.StreamType.unary,
    dzerothgraphv1graph.UnmuteRequest.new,
    dzerothgraphv1graph.UnmuteResponse.new,
  );

  /// Caller's relationship to up to 50 users, computed from the caller's graph doc only (1 read, cached 60 s).
  /// Does not report whether the target follows the caller (that would cost 1 read per user).
  /// Firestore: reads 1/0, writes 0.
  static const getRelationships = connect.Spec(
    '/$name/GetRelationships',
    connect.StreamType.unary,
    dzerothgraphv1graph.GetRelationshipsRequest.new,
    dzerothgraphv1graph.GetRelationshipsResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Followers of a user, newest first. Private accounts: only the owner and approved followers.
  /// Reads: target user + target graph (visibility) + follows page + GetAll users for hydration (cached 60 s).
  /// Firestore: reads 102/25, writes 0.
  static const listFollowers = connect.Spec(
    '/$name/ListFollowers',
    connect.StreamType.unary,
    dzerothgraphv1graph.ListFollowersRequest.new,
    dzerothgraphv1graph.ListFollowersResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Accounts a user follows, newest first. Same cost shape as ListFollowers.
  /// Firestore: reads 102/25, writes 0.
  static const listFollowing = connect.Spec(
    '/$name/ListFollowing',
    connect.StreamType.unary,
    dzerothgraphv1graph.ListFollowingRequest.new,
    dzerothgraphv1graph.ListFollowingResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Caller's blocked accounts (from graph doc) hydrated with GetAll users.
  /// Firestore: reads 51/10, writes 0.
  static const listBlockedUsers = connect.Spec(
    '/$name/ListBlockedUsers',
    connect.StreamType.unary,
    dzerothgraphv1graph.ListBlockedUsersRequest.new,
    dzerothgraphv1graph.ListBlockedUsersResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Caller's muted accounts (from graph doc) hydrated with GetAll users.
  /// Firestore: reads 51/10, writes 0.
  static const listMutedUsers = connect.Spec(
    '/$name/ListMutedUsers',
    connect.StreamType.unary,
    dzerothgraphv1graph.ListMutedUsersRequest.new,
    dzerothgraphv1graph.ListMutedUsersResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );
}
