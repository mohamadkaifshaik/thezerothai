//
//  Generated code. Do not modify.
//  source: dzeroth/graph/v1/graph.proto
//

import "package:connectrpc/connect.dart" as connect;
import "graph.pb.dart" as dzerothgraphv1graph;
import "graph.connect.spec.dart" as specs;

extension type GraphServiceClient (connect.Transport _transport) {
  /// Follow a user; for private accounts creates a follow request instead. Quota: 200 follows/day.
  /// Cap: 5,000 following (graph doc size). Reads: caller graph (cached), target user (cached), target graph
  /// (blocked-by + privacy), quotas/{uid}. Writes: follows doc, caller graph, caller users counter, target users
  /// counter, quotas. Private target: followRequests doc + caller graph.requested + quotas.
  /// Async: 1 notification write (notifications module).
  /// Firestore: reads 4/2, writes 5/5 (+1 async).
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

  /// Unfollow or cancel a pending request. No-op if not following (per cached graph re-checked in the batch precondition).
  /// Firestore: reads 1/0, writes 3/3, deletes 1/1.
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

  /// Incoming follow requests for the caller (private accounts). Hydrated with a batched GetAll of users.
  /// Firestore: reads 100/5 (page + hydration, users cached 60 s), writes 0.
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
  /// Accept: delete request, create follows, requester graph (following += , requested -=), 2 users counters.
  /// Firestore: reads 1/1, writes 4/4, deletes 1/1.
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

  /// Block: also removes follows in both directions. Idempotent (ArrayUnion).
  /// Worst (mutual follow): caller graph, target graph, both users docs + 2 follows deletes.
  /// Firestore: reads 2/1, writes 4/1, deletes 2/0.
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

  /// Firestore: reads 0/0, writes 1/1.
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

  /// Mute hides the target's posts from the caller's timelines only. Idempotent (ArrayUnion).
  /// Firestore: reads 0/0, writes 1/1.
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

  /// Firestore: reads 0/0, writes 1/1.
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
  /// Does not report whether the target follows the caller (that would cost 1 read per user).
  /// Firestore: reads 1/0, writes 0.
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

  /// Followers of a user, newest first. Private accounts: only the owner and approved followers.
  /// Reads: target user + target graph (visibility) + follows page + GetAll users for hydration (cached 60 s).
  /// Firestore: reads 102/25, writes 0.
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

  /// Accounts a user follows, newest first. Same cost shape as ListFollowers.
  /// Firestore: reads 102/25, writes 0.
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

  /// Caller's blocked accounts (from graph doc) hydrated with GetAll users.
  /// Firestore: reads 51/10, writes 0.
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

  /// Caller's muted accounts (from graph doc) hydrated with GetAll users.
  /// Firestore: reads 51/10, writes 0.
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
