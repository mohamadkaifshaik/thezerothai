import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/notifications/data/notifications_repository.dart';
import 'package:dzeroth/features/notifications/data/notifications_store.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/notifications_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/unread_badge_cubit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/notifications_fixtures.dart';

class MockNotificationsRepository extends Mock
    implements NotificationsRepository {}

void main() {
  late MockNotificationsRepository repo;
  late UnreadBadgeCubit badge;
  late NotificationsCubit cubit;
  Duration? since;

  setUp(() {
    since = null;
    repo = MockNotificationsRepository();
    badge = UnreadBadgeCubit(3);
    when(() => repo.sinceRefresh).thenAnswer((_) => since);
    when(() => repo.sinceRefreshAttempt).thenAnswer((_) => since);
    when(() => repo.rateLimitedFor()).thenReturn(null);
    when(() => repo.markSeen(any()))
        .thenAnswer((_) async => kNotifBase.add(const Duration(seconds: 1)));
    cubit = NotificationsCubit(repository: repo, badge: badge);
  });

  tearDown(() async {
    await cubit.close();
    await badge.close();
  });

  final seenBefore = kNotifBase.subtract(const Duration(minutes: 10));

  test('load: cache first, then refresh, then mark seen once and clear the '
      'badge while the rows stay highlighted', () async {
    when(() => repo.cached()).thenAnswer(
      (_) async =>
          snapshotOfNotifs([notif('b', minutesAgo: 20)], seenAt: seenBefore),
    );
    final refreshed = Completer<NotificationsSnapshot>();
    when(() => repo.refresh()).thenAnswer((_) => refreshed.future);

    final loading = cubit.load();
    await pumpEventQueue();
    // Cached rows are visible while the refresh is in flight.
    expect(cubit.state.entries.map((e) => e.itemKey), ['b']);
    expect(cubit.state.refreshing, isTrue);

    refreshed.complete(
      snapshotOfNotifs([
        notif('a', minutesAgo: 1),
        notif('b', minutesAgo: 20),
      ], seenAt: seenBefore),
    );
    await loading;
    await pumpEventQueue();

    expect(cubit.state.status, NotificationsStatus.ready);
    expect(cubit.state.entries, hasLength(2));
    verify(() => repo.markSeen(any())).called(1);
    expect(badge.state, 0);
    // Highlight keeps the pre-visit seen_at: "a" is still shown as new.
    expect(cubit.state.highlightSince, seenBefore);
  });

  test('nothing newer than seen_at and no badge: no mark-seen call', () async {
    badge = UnreadBadgeCubit(0);
    cubit = NotificationsCubit(repository: repo, badge: badge);
    final all = snapshotOfNotifs([
      notif('b', minutesAgo: 20),
    ], seenAt: seenBefore);
    when(() => repo.cached()).thenAnswer((_) async => all);
    when(() => repo.refresh()).thenAnswer((_) async => all);

    await cubit.load();
    await pumpEventQueue();

    verifyNever(() => repo.markSeen(any()));
  });

  test('a mark-seen failure is silent', () async {
    when(() => repo.cached()).thenAnswer((_) async => snapshotOfNotifs([]));
    when(() => repo.refresh())
        .thenAnswer((_) async => snapshotOfNotifs([notif('a', minutesAgo: 1)]));
    when(() => repo.markSeen(any())).thenThrow(
      const RateLimitedException('cap', limitName: 'notification_seen_daily'),
    );

    await cubit.load();
    await pumpEventQueue();

    expect(cubit.state.status, NotificationsStatus.ready);
    expect(cubit.state.error, isNull);
    expect(cubit.state.notice, isNull);
    // The badge stays: nothing was marked.
    expect(badge.state, 3);
  });

  test('a failure with nothing cached is a blocking error; with rows it is '
      'a notice', () async {
    when(() => repo.cached()).thenAnswer((_) async => snapshotOfNotifs([]));
    when(() => repo.refresh()).thenThrow(const NetworkException('offline'));

    await cubit.load();
    expect(cubit.state.status, NotificationsStatus.error);
    expect(cubit.state.error, isA<NetworkException>());

    final cached = snapshotOfNotifs([
      notif('a', minutesAgo: 1),
    ], seenAt: kNotifBase);
    when(() => repo.cached()).thenAnswer((_) async => cached);
    final second = NotificationsCubit(repository: repo, badge: badge);
    addTearDown(second.close);
    await second.load();

    expect(second.state.status, NotificationsStatus.ready);
    expect(second.state.error, isNull);
    expect(second.state.notice, isA<NetworkException>());
  });

  test('recently refreshed: no RPC on open', () async {
    since = const Duration(seconds: 10);
    when(() => repo.cached()).thenAnswer(
      (_) async => snapshotOfNotifs([notif('a')], seenAt: kNotifBase),
    );

    await cubit.load();

    verifyNever(() => repo.refresh());
  });

  test('loadMore appends once, guarded against concurrent calls', () async {
    when(() => repo.cached()).thenAnswer(
      (_) async => snapshotOfNotifs(
        [notif('a', minutesAgo: 1)],
        older: 'p1',
        seenAt: kNotifBase,
      ),
    );
    when(() => repo.refresh()).thenAnswer(
      (_) async => snapshotOfNotifs(
        [notif('a', minutesAgo: 1)],
        older: 'p1',
        seenAt: kNotifBase,
      ),
    );
    final page = Completer<NotificationsSnapshot>();
    when(() => repo.loadOlder()).thenAnswer((_) => page.future);
    await cubit.load();

    final first = cubit.loadMore();
    final second = cubit.loadMore();
    expect(cubit.state.loadingMore, isTrue);
    page.complete(
      snapshotOfNotifs([
        notif('a', minutesAgo: 1),
        notif('z', minutesAgo: 90),
      ], seenAt: kNotifBase),
    );
    await Future.wait([first, second]);

    verify(() => repo.loadOlder()).called(1);
    expect(cubit.state.entries.map((e) => e.itemKey), ['a', 'z']);
    expect(cubit.state.hasMore, isFalse);
  });

  test('a failed page shows the inline retry and stops auto paging', () async {
    when(() => repo.cached()).thenAnswer(
      (_) async =>
          snapshotOfNotifs([notif('a')], older: 'p1', seenAt: kNotifBase),
    );
    when(() => repo.refresh()).thenAnswer(
      (_) async =>
          snapshotOfNotifs([notif('a')], older: 'p1', seenAt: kNotifBase),
    );
    when(() => repo.loadOlder()).thenThrow(const NetworkException('offline'));
    await cubit.load();

    await cubit.loadMore();
    expect(cubit.state.loadMoreFailed, isTrue);
    await cubit.loadMore();
    verify(() => repo.loadOlder()).called(1);

    when(() => repo.loadOlder()).thenAnswer(
      (_) async => snapshotOfNotifs([notif('a')], seenAt: kNotifBase),
    );
    await cubit.retryLoadMore();
    expect(cubit.state.loadMoreFailed, isFalse);
  });

  test('a held RATE_LIMITED answer skips automatic refreshes', () async {
    when(() => repo.cached()).thenAnswer(
      (_) async => snapshotOfNotifs([notif('a')], seenAt: kNotifBase),
    );
    when(() => repo.rateLimitedFor()).thenReturn(
      const RateLimitedException(
        'daily',
        limitName: 'read_budget_daily',
        retryAfter: Duration(hours: 2),
      ),
    );

    await cubit.refreshIfStale();
    verifyNever(() => repo.refresh());
  });
}
