import 'dart:async';

import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/network/connect_error_mapper.dart';
import 'package:dzeroth/features/engagement/data/poll_repository.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/poll_cubit.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/poll_state.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/engagement/v1/engagement.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import '../../../../support/fake_transport.dart';
import '../../../../support/poll_fixtures.dart';
import '../../../../support/posts_fixtures.dart';

void main() {
  late FakeTransport transport;
  late PollCubit cubit;
  late List<pb.VotePollRequest> sent;
  late Future<Object> Function() answer;
  late int reads;
  late Future<Object> Function() readAnswer;

  final id = postId(1);

  setUp(() {
    sent = [];
    reads = 0;
    answer = () async => throw StateError('unscripted');
    readAnswer = () async => pollPostView(
      1,
      poll: pollOf(visible: true, votes: [2, 1, 0], total: 3, closed: true),
      choice: 1,
    );
    transport = FakeTransport((procedure, input) async {
      sent.add(input as pb.VotePollRequest);
      final r = await answer();
      if (r is Exception) throw r;
      return r;
    });
    final repo = PollRepository(
      apiClient: ApiClient.withTransport(transport),
      gate: ServiceFeatureGate(isEnabled: () => true),
      readPost: (_) async {
        reads++;
        final r = await readAnswer();
        if (r is Exception) throw mapConnectError(r);
        return r as dynamic;
      },
    );
    cubit = PollCubit(repository: repo, uuid: const Uuid());
  });

  tearDown(() => cubit.close());

  Future<Object> success() async => pb.VotePollResponse(
    post: pollPostView(
      1,
      poll: pollOf(visible: true, votes: [0, 3, 1], total: 4),
      choice: 2,
    ),
  );

  test(
    'vote marks the choice at once, then keeps the committed counts',
    () async {
      final gate = Completer<Object>();
      answer = () => gate.future;

      final done = cubit.vote(id, 1);
      await pumpEventQueue();
      expect(cubit.state.entries[id]!.pendingChoice, 1);

      gate.complete(await success());
      await done;

      final entry = cubit.state.entries[id]!;
      expect(entry.pendingChoice, isNull);
      expect(entry.fresh!.viewerPollChoice, 2);
      expect(sent, hasLength(1));
      expect(sent.single.choiceIndex, 1);
      expect(cubit.state.failure, isNull);
    },
  );

  test('a second tap while one vote is in flight sends nothing', () async {
    final gate = Completer<Object>();
    answer = () => gate.future;
    final first = cubit.vote(id, 1);
    await pumpEventQueue();
    await cubit.vote(id, 2);
    gate.complete(await success());
    await first;
    expect(sent, hasLength(1));
  });

  test(
    'a failed vote rolls back, reports once, and the retry reuses the key',
    () async {
      answer = () async =>
          connect.ConnectException(connect.Code.unavailable, 'x');
      await cubit.vote(id, 1);

      expect(cubit.state.entries[id]!.pendingChoice, isNull);
      expect(cubit.state.failure!.postId, id);
      expect(cubit.state.failure!.action, PollAction.vote);
      expect(cubit.state.failure!.error, isA<NetworkException>());
      cubit.failureShown();
      expect(cubit.state.failure, isNull);

      answer = success;
      await cubit.vote(id, 1);
      expect(sent, hasLength(2));
      expect(sent[1].idempotencyKey, sent[0].idempotencyKey);
      expect(cubit.state.entries[id]!.fresh, isNotNull);

      // A different choice is a different intent: its own key.
      answer = () async =>
          connect.ConnectException(connect.Code.unavailable, 'x');
      await cubit.vote(postId(2), 0);
      await cubit.vote(postId(2), 1);
      expect(sent[2].idempotencyKey, isNot(sent[3].idempotencyKey));
    },
  );

  test(
    'ALREADY_VOTED re-reads the post once and keeps the server choice',
    () async {
      answer = () async => serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_ALREADY_VOTED,
        metadata: {'choice': '0'},
      );
      await cubit.vote(id, 2);

      expect(reads, 1);
      final entry = cubit.state.entries[id]!;
      expect(entry.knownChoice, 0);
      expect(entry.fresh!.viewerPollChoice, 1);
      expect(cubit.state.failure, isNull);
    },
  );

  test('ALREADY_VOTED with a failing re-read still shows the choice', () async {
    answer = () async => serverError(
      connect.Code.failedPrecondition,
      common.ErrorReason.ERROR_REASON_ALREADY_VOTED,
      metadata: {'choice': '1'},
    );
    readAnswer = () async =>
        connect.ConnectException(connect.Code.unavailable, 'x');
    await cubit.vote(id, 2);

    final entry = cubit.state.entries[id]!;
    expect(entry.knownChoice, 1);
    expect(entry.fresh, isNull);
    expect(entry.pendingChoice, isNull);
  });

  test('POLL_CLOSED re-reads once and marks the poll closed', () async {
    answer = () async => serverError(
      connect.Code.failedPrecondition,
      common.ErrorReason.ERROR_REASON_POLL_CLOSED,
    );
    await cubit.vote(id, 0);

    expect(reads, 1);
    final entry = cubit.state.entries[id]!;
    expect(entry.closed, isTrue);
    expect(entry.fresh!.post.poll.resultsVisible, isTrue);
  });

  test('FEATURE_DISABLED hides voting and says so once', () async {
    answer = () async => serverError(
      connect.Code.failedPrecondition,
      common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
      metadata: {'feature': 'polls'},
    );
    await cubit.vote(id, 0);

    expect(cubit.state.votingOff, isTrue);
    expect(cubit.votingOff, isTrue);
    expect(cubit.state.failure!.error, isA<FeatureDisabledException>());

    cubit.flagsChanged();
    expect(cubit.state.votingOff, isFalse);
    expect(cubit.votingOff, isFalse);
  });

  test('refresh is exactly one GetPost, and a failure is reported', () async {
    await cubit.refresh(id);
    expect(reads, 1);
    expect(cubit.state.entries[id]!.fresh!.post.poll.closed, isTrue);
    expect(cubit.state.entries[id]!.refreshing, isFalse);

    readAnswer = () async =>
        connect.ConnectException(connect.Code.unavailable, 'x');
    await cubit.refresh(postId(2));
    expect(cubit.state.failure!.action, PollAction.refresh);
    expect(cubit.state.entries[postId(2)]!.refreshing, isFalse);
  });

  test('reset forgets everything and ignores a late answer', () async {
    final gate = Completer<Object>();
    answer = () => gate.future;
    final done = cubit.vote(id, 1);
    await pumpEventQueue();

    cubit.reset();
    expect(cubit.state.entries, isEmpty);

    gate.complete(await success());
    await done;
    expect(cubit.state.entries, isEmpty);
  });
}
