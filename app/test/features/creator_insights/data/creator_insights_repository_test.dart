import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/creator_insights/data/creator_insights_repository.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/creator_insights_fixtures.dart';
import '../../../support/fake_transport.dart';

void main() {
  test('sends the window; with the flag off sends nothing', () async {
    final requests = <pb.GetCreatorInsightsRequest>[];
    final transport = FakeTransport((procedure, input) async {
      requests.add(input as pb.GetCreatorInsightsRequest);
      return insightsResponse(days: 7);
    });
    var on = true;
    final repo = CreatorInsightsRepository(
      apiClient: ApiClient.withTransport(transport),
      gate: ServiceFeatureGate(isEnabled: () => on),
    );

    final r = await repo.load(windowDays: 7);
    expect(r.windowDays, 7);
    expect(requests.single.windowDays, 7);
    expect(transport.calledProcedures.single, endsWith('/GetCreatorInsights'));

    on = false;
    await expectLater(repo.load(), throwsA(isA<FeatureDisabledException>()));
    expect(transport.calledProcedures, hasLength(1));
  });
}
