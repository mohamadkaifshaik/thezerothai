import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/notifications/data/notifications_repository.dart';
import 'package:dzeroth/features/notifications/data/notifications_store.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/notifications_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/unread_badge_cubit.dart';
import 'package:dzeroth/features/posts/domain/posts_feature_flag.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/gen/dzeroth/notifications/v1/notifications.pb.dart'
    as pb;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_transport.dart';
import '../../../support/notifications_fixtures.dart';

const _list = '/dzeroth.notifications.v1.NotificationService/ListNotifications';
const _seen =
    '/dzeroth.notifications.v1.NotificationService/MarkNotificationsSeen';

/// The notifications list on the start-up fallback with no sqlite at all
/// (`AppDatabase.keepingNothing`, e.g. the web without `sqlite3.wasm`): the
/// rows the server returned stay in memory for the session and render. Real
/// repository and store, fake transport.
void main() {
  late AppDatabase db;
  late List<pb.ListNotificationsRequest> requests;
  late List<pb.ListNotificationsResponse> answers;
  late FakeTransport transport;
  late NotificationsRepository repo;
  late UnreadBadgeCubit badge;
  final cubits = <NotificationsCubit>[];

  List<String> keys(NotificationsCubit c) => [
    for (final e in c.state.entries) e.itemKey,
  ];

  NotificationsCubit cubit() {
    final c = NotificationsCubit(repository: repo, badge: badge);
    cubits.add(c);
    return c;
  }

  setUp(() {
    db = AppDatabase.keepingNothing();
    requests = [];
    answers = [];
    transport = FakeTransport((procedure, input) async {
      if (procedure == _list) {
        requests.add(input as pb.ListNotificationsRequest);
        if (answers.isEmpty) throw StateError('unscripted $procedure');
        return answers.removeAt(0);
      }
      if (procedure == _seen) return pb.MarkNotificationsSeenResponse();
      throw StateError('unexpected $procedure');
    });
    repo = NotificationsRepository(
      apiClient: ApiClient.withTransport(transport),
      store: NotificationsStore(db),
      gate: ServiceFeatureGate(isEnabled: () => true),
    );
    badge = UnreadBadgeCubit();
  });

  tearDown(() async {
    for (final c in cubits) {
      await c.close();
    }
    cubits.clear();
    await badge.close();
    await db.close();
  });

  test('the first page the server returned renders', () async {
    await db.claimCacheFor('a');
    answers.add(
      listResponse(
        [notif('n3', minutesAgo: 1), notif('n2', minutesAgo: 2)],
        since: 's1',
        next: 'older',
      ),
    );
    final list = cubit();

    await list.load();

    expect(requests, hasLength(1));
    expect(list.state.status, NotificationsStatus.ready);
    expect(keys(list), ['n3', 'n2']);
    expect(list.state.hasMore, isTrue);
  });

  test('paging appends the older page', () async {
    answers
      ..add(
        listResponse(
          [notif('n3', minutesAgo: 1), notif('n2', minutesAgo: 2)],
          since: 's1',
          next: 'older',
        ),
      )
      ..add(listResponse([notif('n1', minutesAgo: 3)]));
    final list = cubit();
    await list.load();

    await list.loadMore();

    expect(requests.last.pageToken, 'older');
    expect(keys(list), ['n3', 'n2', 'n1']);
    expect(list.state.hasMore, isFalse);
  });

  test('a refresh sends the kept since_token and adds the newer rows on '
      'top', () async {
    answers
      ..add(listResponse([notif('n2', minutesAgo: 2)], since: 's1'))
      ..add(listResponse([notif('n4', minutesAgo: 0)], since: 's2'));
    final list = cubit();
    await list.load();

    await list.refresh();

    expect(requests.last.sinceToken, 's1');
    expect(keys(list), ['n4', 'n2']);
    expect(
      [for (final e in (await repo.cached()).entries) e.itemKey],
      ['n4', 'n2'],
    );
  });

  test('an account switch clears the rows: the next account never sees '
      'them', () async {
    await db.claimCacheFor('a');
    answers.add(listResponse([notif('mine-a')], since: 's1'));
    await cubit().load();
    expect(
      [for (final e in (await repo.cached()).entries) e.itemKey],
      ['mine-a'],
      reason: 'kept',
    );

    // What `wireAuthSession` runs for a switch from a to b.
    await wipeSessionData(
      database: db,
      timelineRepository: TimelineRepository(
        apiClient: ApiClient.withTransport(transport),
        store: TimelineStore(db),
        gate: PostsFeatureGate(isPostsEnabled: () => true),
      ),
      notificationsRepository: repo,
    );
    await db.claimCacheFor('b');

    expect((await repo.cached()).entries, isEmpty);
    answers.add(listResponse([notif('mine-b')], since: 'b1'));
    final list = cubit();
    await list.load();
    expect(requests.last.sinceToken, isEmpty, reason: "a's token is gone");
    expect(keys(list), ['mine-b']);
  });
}
