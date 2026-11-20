import 'dart:typed_data';

import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/features/moderation/data/moderation_repository.dart';
import 'package:dzeroth/gen/dzeroth/moderation/v1/moderation.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/moderation/v1/moderation.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_transport.dart';

void main() {
  late List<pb.ReportContentRequest> requests;
  late ModerationRepository repo;

  setUp(() {
    requests = [];
    repo = ModerationRepository(
      apiClient: ApiClient.withTransport(
        FakeTransport((procedure, input) async {
          requests.add(input as pb.ReportContentRequest);
          return pb.ReportContentResponse(reportId: 'r1');
        }),
      ),
      gate: ServiceFeatureGate(isEnabled: () => true),
    );
  });

  Future<ReportReceipt> report({Uint8List? payload}) => repo.report(
    idempotencyKey: '11111111-1111-4111-8111-111111111111',
    targetType: ReportTargetType.REPORT_TARGET_TYPE_POST,
    targetId: '123',
    reason: ReportReason.REPORT_REASON_SPAM,
    messagePayload: payload,
  );

  test('the payload is sent when given and absent otherwise', () async {
    await report();
    expect(requests.last.hasMessagePayload(), isFalse);
    await report(payload: Uint8List.fromList([1, 2, 3]));
    expect(requests.last.messagePayload, [1, 2, 3]);
    await report(payload: Uint8List(8192));
    expect(requests.last.messagePayload, hasLength(8192));
  });

  test('an empty or 8193-byte payload is refused', () async {
    await expectLater(report(payload: Uint8List(0)), throwsArgumentError);
    await expectLater(report(payload: Uint8List(8193)), throwsArgumentError);
    expect(requests, isEmpty);
  });
}
