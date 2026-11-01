import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/engagement/data/poll_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/engagement/v1/engagement.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as posts_pb;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_transport.dart';
import '../../../support/poll_fixtures.dart';
import '../../../support/posts_fixtures.dart';

const _vote = '/dzeroth.engagement.v1.EngagementService/VotePoll';

void main() {
  late FakeTransport transport;
  late PollRepository repo;
  late ServiceFeatureGate gate;
  late List<Object> requests;
  late Object Function() answer;
  var enabled = true;
  var reads = <String>[];

  setUp(() {
    enabled = true;
    reads = [];
    requests = [];
    answer = () => throw StateError('unscripted');
    transport = FakeTransport((procedure, input) async {
      requests.add(input);
      final r = answer();
      if (r is Exception) throw r;
      return r;
    });
    gate = ServiceFeatureGate(isEnabled: () => enabled);
    repo = PollRepository(
      apiClient: ApiClient.withTransport(transport),
      gate: gate,
      readPost: (id) async {
        reads.add(id);
        return pollPostView(
          1,
          poll: pollOf(visible: true, votes: [1, 0, 0], total: 1),
          choice: 1,
        );
      },
    );
  });

  pb.VotePollResponse ok() => pb.VotePollResponse(
    post: pollPostView(
      1,
      poll: pollOf(visible: true, votes: [0, 3, 1], total: 4),
      choice: 2,
    ),
  );

  test(
    'a change sends expected_choice (1-based), a first vote leaves it unset',
    () async {
      answer = ok;
      await repo.vote(
        postId: postId(1),
        choiceIndex: 1,
        idempotencyKey: 'key-change-1234567890',
        expectedChoice: 1,
      );
      await repo.vote(
        postId: postId(1),
        choiceIndex: 1,
        idempotencyKey: 'key-first-12345678901',
      );
      final changed = requests[0] as pb.VotePollRequest;
      final first = requests[1] as pb.VotePollRequest;
      expect(changed.expectedChoice, 1);
      expect(first.hasExpectedChoice(), isFalse);
      expect(first.expectedChoice, 0);
    },
  );

  test(
    'vote sends one VotePoll with post, 0-based choice and the key',
    () async {
      answer = ok;

      final view = await repo.vote(
        postId: postId(1),
        choiceIndex: 1,
        idempotencyKey: 'key-vote-1234567890',
      );

      expect(transport.calledProcedures, [_vote]);
      final sent = requests.single as pb.VotePollRequest;
      expect(sent.postId, postId(1));
      expect(sent.choiceIndex, 1);
      expect(sent.idempotencyKey, 'key-vote-1234567890');
      expect(view.viewerPollChoice, 2);
      expect(view.post.poll.resultsVisible, isTrue);
    },
  );

  test('engagement off: no RPC, FeatureDisabledException', () async {
    enabled = false;
    await expectLater(
      repo.vote(postId: postId(1), choiceIndex: 0, idempotencyKey: 'k' * 16),
      throwsA(isA<FeatureDisabledException>()),
    );
    expect(transport.calledProcedures, isEmpty);
    expect(repo.canVote, isFalse);
  });

  test('POLL_CLOSED maps to PollClosedException', () async {
    answer = () => serverError(
      connect.Code.failedPrecondition,
      common.ErrorReason.ERROR_REASON_POLL_CLOSED,
    );
    await expectLater(
      repo.vote(postId: postId(1), choiceIndex: 0, idempotencyKey: 'k' * 16),
      throwsA(isA<PollClosedException>()),
    );
  });

  test('ALREADY_VOTED carries the server choice (0-based)', () async {
    answer = () => serverError(
      connect.Code.failedPrecondition,
      common.ErrorReason.ERROR_REASON_ALREADY_VOTED,
      metadata: {'choice': '2'},
    );
    await expectLater(
      repo.vote(postId: postId(1), choiceIndex: 0, idempotencyKey: 'k' * 16),
      throwsA(
        isA<AlreadyVotedException>().having((e) => e.choiceIndex, 'choice', 2),
      ),
    );
  });

  test('FEATURE_DISABLED for polls hides voting but not the gate', () async {
    answer = () => serverError(
      connect.Code.failedPrecondition,
      common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
      metadata: {'feature': 'polls'},
    );
    await expectLater(
      repo.vote(postId: postId(1), choiceIndex: 0, idempotencyKey: 'k' * 16),
      throwsA(isA<FeatureDisabledException>()),
    );
    expect(repo.votingOff, isTrue);
    expect(repo.canVote, isFalse);
    // Likes and reposts share the gate and stay on.
    expect(gate.enabled, isTrue);

    // Remembered: the next vote sends nothing.
    await expectLater(
      repo.vote(postId: postId(1), choiceIndex: 0, idempotencyKey: 'k' * 16),
      throwsA(isA<FeatureDisabledException>()),
    );
    expect(transport.calledProcedures, hasLength(1));

    repo.reset();
    expect(repo.canVote, isTrue);
  });

  test('UNIMPLEMENTED (the skeleton) reads as voting off, no report', () async {
    answer = () => connect.ConnectException(connect.Code.unimplemented, 'no');
    await expectLater(
      repo.vote(postId: postId(1), choiceIndex: 0, idempotencyKey: 'k' * 16),
      throwsA(isA<FeatureDisabledException>()),
    );
    expect(repo.votingOff, isTrue);
  });

  test('refresh reads the post once through readPost', () async {
    final view = await repo.refresh(postId(7));
    expect(reads, [postId(7)]);
    expect(view, isA<posts_pb.PostView>());
  });
}
