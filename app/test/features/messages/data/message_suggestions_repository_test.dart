import 'package:connectrpc/connect.dart' as connect;
import 'package:drift/native.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/network/rate_limit_hold.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_gate.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_transport.dart';
import '../../../support/messaging_fixtures.dart' show withDetail;

void main() {
  late AppDatabase db;
  late FakeTransport transport;
  late MessagingRepository repo;
  late MessagingFeatureGate gate;
  late Object Function(Object input) answer;
  final requests = <pb.ListMessageSuggestionsRequest>[];

  setUp(() {
    requests.clear();
    answer = (_) => pb.ListMessageSuggestionsResponse();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    gate = MessagingFeatureGate(isMessagingEnabled: () => true);
    transport = FakeTransport((procedure, input) async {
      requests.add(input as pb.ListMessageSuggestionsRequest);
      return answer(input);
    });
    repo = MessagingRepository(
      apiClient: ApiClient.withTransport(transport),
      store: MessagingStore(db),
      gate: gate,
      rateLimitHold: RateLimitHold(),
    );
    addTearDown(db.close);
  });

  test('sends the limit and returns the suggestions in order', () async {
    answer = (_) => pb.ListMessageSuggestionsResponse(
      suggestions: [
        pb.MessageSuggestion(user: common.AuthorSnapshot(userId: 'a')),
        pb.MessageSuggestion(user: common.AuthorSnapshot(userId: 'b')),
      ],
    );
    final rows = await repo.listMessageSuggestions(limit: 7);
    expect(rows.map((s) => s.user.userId), ['a', 'b']);
    expect(requests.single.limit, 7);
  });

  test('its FEATURE_DISABLED does not switch messaging reads off', () async {
    answer = (_) => throw withDetail(
      connect.Code.failedPrecondition,
      common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
      metadata: {'feature': 'dm_suggestions'},
    );
    await expectLater(
      repo.listMessageSuggestions(),
      throwsA(isA<FeatureDisabledException>()),
    );
    expect(gate.canSend, isTrue);
  });

  test('RATE_LIMITED is held: the next call sends nothing', () async {
    answer = (_) => throw withDetail(
      connect.Code.resourceExhausted,
      common.ErrorReason.ERROR_REASON_RATE_LIMITED,
      metadata: {'limit': 'dm_suggestions_per_min'},
    );
    await expectLater(
      repo.listMessageSuggestions(),
      throwsA(isA<RateLimitedException>()),
    );
    await expectLater(
      repo.listMessageSuggestions(),
      throwsA(isA<RateLimitedException>()),
    );
    expect(requests, hasLength(1));
  });
}
