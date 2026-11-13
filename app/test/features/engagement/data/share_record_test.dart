import 'dart:async';

import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/features/engagement/data/engagement_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/engagement/v1/engagement.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/engagement/v1/engagement.pbenum.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_transport.dart';
import '../../../support/messaging_fixtures.dart' show withDetail;
import '../../../support/posts_fixtures.dart';

const _service = '/dzeroth.engagement.v1.EngagementService/';

void main() {
  late FakeTransport transport;
  late EngagementRepository repo;
  late List<Object> requests;
  late Object Function(String procedure) answer;
  var likesOn = true;
  var shareOn = true;
  var reported = 0;

  pb.RecordPostShareResponse counted(int n, {bool counted = true}) =>
      pb.RecordPostShareResponse(
        counted: counted,
        engagement: pb.PostEngagement(postId: postId(1), shareCount: Int64(n)),
      );

  setUp(() {
    likesOn = true;
    shareOn = true;
    reported = 0;
    requests = [];
    answer = (_) => counted(1);
    transport = FakeTransport((procedure, input) async {
      requests.add(input);
      final r = answer(procedure);
      if (r is Exception) throw r;
      return r;
    });
    repo = EngagementRepository(
      apiClient: ApiClient.withTransport(transport),
      gate: ServiceFeatureGate(isEnabled: () => likesOn),
      shareGate: ServiceFeatureGate(
        isEnabled: () => shareOn,
        onUnexpectedError: (_, _) => reported++,
      ),
    );
  });

  Future<pb.PostEngagement?> record({
    String id = '',
    ShareChannel channel = ShareChannel.SHARE_CHANNEL_COPY_LINK,
  }) => repo.recordPostShare(
    postId: id.isEmpty ? postId(1) : id,
    channel: channel,
  );

  test('sends the post, the channel and a valid key, and returns the '
      'engagement', () async {
    final out = await record(channel: ShareChannel.SHARE_CHANNEL_SHARE_SHEET);

    expect(transport.calledProcedures, ['${_service}RecordPostShare']);
    final sent = requests.single as pb.RecordPostShareRequest;
    expect(sent.postId, postId(1));
    expect(sent.channel, ShareChannel.SHARE_CHANNEL_SHARE_SHEET);
    expect(sent.idempotencyKey, matches(RegExp(r'^[A-Za-z0-9_-]{16,64}$')));
    expect(out!.shareCount.toInt(), 1);
  });

  test('once per post per session: a repeat sends nothing', () async {
    await record();
    expect(await record(), isNull);
    expect(
      await record(channel: ShareChannel.SHARE_CHANNEL_SHARE_SHEET),
      isNull,
    );
    expect(transport.calledProcedures, hasLength(1));
    // Another post is its own.
    await record(id: postId(2));
    expect(transport.calledProcedures, hasLength(2));
  });

  test('two taps while one report is in flight send one request', () async {
    final gate = Completer<void>();
    transport = FakeTransport((procedure, input) async {
      requests.add(input);
      await gate.future;
      return counted(1);
    });
    repo = EngagementRepository(
      apiClient: ApiClient.withTransport(transport),
      gate: ServiceFeatureGate(isEnabled: () => true),
      shareGate: ServiceFeatureGate(isEnabled: () => true),
    );
    final first = record();
    final second = record();
    gate.complete();

    expect(await second, isNull);
    expect(await first, isNotNull);
    expect(requests, hasLength(1));
  });

  test('with share_count off for the caller no request is sent', () async {
    shareOn = false;
    expect(await record(), isNull);
    expect(transport.calledProcedures, isEmpty);
  });

  test('no share gate (an older wiring): nothing is sent', () async {
    repo = EngagementRepository(
      apiClient: ApiClient.withTransport(transport),
      gate: ServiceFeatureGate(isEnabled: () => true),
    );
    expect(await record(), isNull);
    expect(transport.calledProcedures, isEmpty);
  });

  test(
    'a failure is swallowed, forgotten, and never retried by itself',
    () async {
      answer = (_) => connect.ConnectException(connect.Code.unavailable, 'x');
      expect(await record(), isNull);
      expect(transport.calledProcedures, hasLength(1));

      // A later share of the same post may report again.
      answer = (_) => counted(2);
      expect((await record())!.shareCount.toInt(), 2);
      expect(transport.calledProcedures, hasLength(2));
    },
  );

  test('a non-protocol error is swallowed too', () async {
    answer = (_) => throw StateError('boom');
    expect(await record(), isNull);
  });

  test('a FEATURE_DISABLED for share_count never turns likes off', () async {
    answer = (_) => withDetail(
      connect.Code.failedPrecondition,
      common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
      metadata: {'feature': 'share_count'},
    );
    expect(await record(), isNull);
    // The share gate remembers it: no more share requests this session...
    expect(await record(id: postId(2)), isNull);
    expect(transport.calledProcedures, hasLength(1));

    // ...and a like still goes out through its own gate.
    answer = (_) => pb.LikePostResponse(
      engagement: pb.PostEngagement(postId: postId(1), likeCount: Int64(1)),
    );
    final liked = await repo.like(
      postId: postId(1),
      idempotencyKey: 'k-like-1234567890',
    );
    expect(liked.likeCount.toInt(), 1);
    expect(transport.calledProcedures.last, '${_service}LikePost');
  });

  test('clearSession forgets what was reported (sign-out)', () async {
    await record();
    repo.clearShareSession();
    expect(await record(), isNotNull);
    expect(transport.calledProcedures, hasLength(2));
  });

  test('an answer that lands after sign-out is dropped', () async {
    final gate = Completer<void>();
    transport = FakeTransport((procedure, input) async {
      await gate.future;
      return counted(5);
    });
    repo = EngagementRepository(
      apiClient: ApiClient.withTransport(transport),
      gate: ServiceFeatureGate(isEnabled: () => true),
      shareGate: ServiceFeatureGate(isEnabled: () => true),
    );
    final pending = record();
    repo.clearShareSession();
    gate.complete();
    expect(await pending, isNull);
    // The next session may report the same post.
    transport = FakeTransport((procedure, input) async => counted(6));
    repo = EngagementRepository(
      apiClient: ApiClient.withTransport(transport),
      gate: ServiceFeatureGate(isEnabled: () => true),
      shareGate: ServiceFeatureGate(isEnabled: () => true),
    );
    expect((await record())!.shareCount.toInt(), 6);
  });

  test('an empty post id sends nothing', () async {
    expect(
      await repo.recordPostShare(
        postId: '',
        channel: ShareChannel.SHARE_CHANNEL_COPY_LINK,
      ),
      isNull,
    );
    expect(transport.calledProcedures, isEmpty);
  });
}
