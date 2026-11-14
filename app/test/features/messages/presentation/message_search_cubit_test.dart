import 'package:drift/native.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/rate_limit_hold.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_gate.dart';
import 'package:dzeroth/features/messages/presentation/bloc/message_search_cubit.dart';
import 'package:dzeroth/features/messages/presentation/bloc/message_search_state.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.connect.spec.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_transport.dart';
import '../../../support/messaging_fixtures.dart';

void main() {
  late AppDatabase db;
  late MessagingRepository repository;
  late MessagingStore store;
  final requests = <pb.ListMessagesRequest>[];

  setUp(() {
    requests.clear();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    store = MessagingStore(db);
    final api = ApiClient.withTransport(
      FakeTransport((procedure, input) async {
        if (procedure == '/${MessagingService.name}/ListMessages') {
          final request = input as pb.ListMessagesRequest;
          requests.add(request);
          if (request.pageToken == 'older-1') {
            return pb.ListMessagesResponse(
              messages: [msg(1, secondsAgo: 500, text: 'ancient needle')],
            );
          }
          return pb.ListMessagesResponse(
            messages: [msg(2, secondsAgo: 5, text: 'recent talk')],
            conversation: conv('c1'),
            nextPageToken: 'older-1',
            sinceToken: 's',
          );
        }
        throw UnimplementedError(procedure);
      }),
    );
    repository = MessagingRepository(
      apiClient: api,
      store: store,
      gate: MessagingFeatureGate(isMessagingEnabled: () => true),
      rateLimitHold: RateLimitHold(),
    );
  });
  tearDown(() => db.close());

  test('Load older fetches one page in memory only and searches it', () async {
    await repository.refreshThread('c1');
    final cubit = MessageSearchCubit(
      repository: repository,
      conversationId: 'c1',
      debounce: Duration.zero,
    );
    addTearDown(cubit.close);

    cubit.setQuery('needle');
    await cubit.stream.firstWhere((s) => s.status == MessageSearchStatus.ready);
    expect(cubit.state.hitCount, 0);
    expect(cubit.state.canLoadOlder, isTrue);

    await cubit.loadOlder();
    expect(cubit.state.hitCount, 1);
    expect(cubit.state.olderPages, 1);
    expect(cubit.state.canLoadOlder, isFalse);
    expect(requests.last.pageToken, 'older-1');

    // Not written to the cache (it would be trimmed to 200 anyway).
    final cached = await store.readSearchCorpus(conversationId: 'c1');
    expect(cached.messages['c1']!.map((m) => m.text), ['recent talk']);
  });

  test('a list search has no Load older', () async {
    await repository.refreshThread('c1');
    final cubit = MessageSearchCubit(
      repository: repository,
      debounce: Duration.zero,
    );
    addTearDown(cubit.close);
    cubit.setQuery('recent');
    await cubit.stream.firstWhere((s) => s.status == MessageSearchStatus.ready);
    expect(cubit.state.hitCount, 1);
    expect(cubit.state.canLoadOlder, isFalse);
    cubit.setQuery('');
    expect(cubit.state.status, MessageSearchStatus.idle);
    expect(cubit.state.groups, isEmpty);
  });
}
