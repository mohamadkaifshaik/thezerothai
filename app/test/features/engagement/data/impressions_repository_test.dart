import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/engagement/data/impressions_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/engagement/v1/engagement.pb.dart' as pb;
import 'package:connectrpc/connect.dart' as connect;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_transport.dart';
import '../../../support/posts_fixtures.dart';

void main() {
  late FakeTransport transport;
  late List<Object> requests;
  late bool enabled;
  Object? fail;

  ImpressionsRepository build() => ImpressionsRepository(
    apiClient: ApiClient.withTransport(transport),
    gate: ServiceFeatureGate(isEnabled: () => enabled),
  );

  setUp(() {
    enabled = true;
    fail = null;
    requests = [];
    transport = FakeTransport((procedure, input) async {
      requests.add(input);
      final error = fail;
      if (error != null) throw error;
      return pb.RecordImpressionsResponse();
    });
  });

  test('sends the ids with a fresh valid key per call', () async {
    final repo = build();
    await repo.record([postId(1), postId(2)]);
    await repo.record([postId(3)]);

    final first = requests[0] as pb.RecordImpressionsRequest;
    final second = requests[1] as pb.RecordImpressionsRequest;
    expect(first.postIds, [postId(1), postId(2)]);
    final valid = RegExp(r'^[A-Za-z0-9_-]{16,64}$');
    expect(valid.hasMatch(first.idempotencyKey), isTrue);
    expect(valid.hasMatch(second.idempotencyKey), isTrue);
    expect(first.idempotencyKey, isNot(second.idempotencyKey));
    expect(
      transport.calledProcedures.first,
      '/dzeroth.engagement.v1.EngagementService/RecordImpressions',
    );
  });

  test('flag off: no RPC', () async {
    enabled = false;
    await expectLater(
      build().record([postId(1)]),
      throwsA(isA<FeatureDisabledException>()),
    );
    expect(requests, isEmpty);
  });

  test('FEATURE_DISABLED from the server is a typed error', () async {
    fail = serverError(
      connect.Code.failedPrecondition,
      common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
    );
    await expectLater(
      build().record([postId(1)]),
      throwsA(isA<FeatureDisabledException>()),
    );
  });
}
