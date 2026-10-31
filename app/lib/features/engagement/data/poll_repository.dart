import 'package:connectrpc/connect.dart' as connect;

import '../../../core/network/api_client.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/feature_flags/service_feature_gate.dart';
import '../../../gen/dzeroth/engagement/v1/engagement.pb.dart' as pb;
import '../../../gen/dzeroth/posts/v1/posts.pb.dart' as posts_pb;

/// Talks to `EngagementService.VotePoll` (ADR-0029 D6) and re-reads a poll
/// post: the only `VotePoll` caller (W6-13).
///
/// - Voting needs the `engagement` flag (the same [ServiceFeatureGate] flag
///   as Like): with it off no RPC is sent. The gate itself is only *read*:
///   a FEATURE_DISABLED answer for `feature=polls` must not switch off likes
///   and reposts, so this repository keeps its own "voting is off" memory
///   ([votingOff]) until [reset] (a fresh `GetMe`, sign-out).
/// - UNIMPLEMENTED (the server skeleton, W6-7 not deployed) is read as
///   FEATURE_DISABLED for polls: the vote buttons go away, nothing is
///   reported.
/// - Nothing retries here. [idempotencyKey] is validated for format only (the
///   natural key `pollVotes/{post}_{uid}` is the record, ADR-0029 D7). The
///   caller reuses one key per (post, choice) intent for a first vote and uses
///   a fresh key per tap for a change; a change also carries `expectedChoice`
///   (Amendment 1 A2.2).
/// - Errors are typed: `PollClosedException`, `AlreadyVotedException`,
///   `FeatureDisabledException`, `NotFoundException`, rate limits.
class PollRepository {
  PollRepository({
    required ApiClient apiClient,
    required ServiceFeatureGate gate,
    required Future<posts_pb.PostView> Function(String postId) readPost,
  }) : _apiClient = apiClient,
       _gate = gate,
       _readPost = readPost;

  final ApiClient _apiClient;
  final ServiceFeatureGate _gate;
  final Future<posts_pb.PostView> Function(String postId) _readPost;
  bool _votingOff = false;

  /// Voting may be offered: `engagement` on and not refused for polls.
  bool get canVote => _gate.enabled && !_votingOff;

  /// The server (or a skeleton) refused voting; buttons stay hidden.
  bool get votingOff => _votingOff;

  /// Forget a remembered refusal (a fresh `GetMe`, sign-out).
  void reset() => _votingOff = false;

  /// Votes [choiceIndex] (0-based) in the poll of [postId] (the original for a
  /// REPOST row). Returns the original's `PostView` with the committed counts,
  /// `results_visible` true and `viewer_poll_choice` set.
  ///
  /// [expectedChoice] (`VotePollRequest.expected_choice`, ADR-0029 Amendment
  /// 1) is the vote the caller holds, 1-based as `viewer_poll_choice` is; 0
  /// (default) is a first vote. A server that predates it ignores the field
  /// and answers ALREADY_VOTED to a change.
  Future<posts_pb.PostView> vote({
    required String postId,
    required int choiceIndex,
    required String idempotencyKey,
    int expectedChoice = 0,
  }) async {
    if (!canVote) {
      throw const FeatureDisabledException(
        "Voting isn't available right now.",
        feature: 'polls',
      );
    }
    try {
      final response = await guardApiCall(() async {
        try {
          return await _apiClient.engagement.votePoll(
            pb.VotePollRequest(
              idempotencyKey: idempotencyKey,
              postId: postId,
              choiceIndex: choiceIndex,
              expectedChoice: expectedChoice > 0 ? expectedChoice : null,
            ),
          );
        } on connect.ConnectException catch (error) {
          if (error.code == connect.Code.unimplemented) {
            throw const FeatureDisabledException(
              "Voting isn't available right now.",
              feature: 'polls',
            );
          }
          rethrow;
        }
      });
      return response.post;
    } on FeatureDisabledException {
      _votingOff = true;
      rethrow;
    }
  }

  /// One `GetPost` (the injected [readPost], `PostsRepository.getPost`) for [postId]: the fresh poll after ALREADY_VOTED,
  /// POLL_CLOSED, or "See final results".
  Future<posts_pb.PostView> refresh(String postId) => _readPost(postId);
}
