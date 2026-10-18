import 'package:connectrpc/connect.dart' as connect;
import 'package:drift/native.dart';
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/network/rate_limit_hold.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/notifications/data/notifications_repository.dart';
import 'package:dzeroth/features/notifications/data/notifications_store.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/notifications/v1/notifications.pb.dart'
    as pb;
import 'package:dzeroth/gen/dzeroth/notifications/v1/notifications.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_transport.dart';
import '../../../support/notifications_fixtures.dart';
import '../../../support/posts_fixtures.dart';

const _list = '/dzeroth.notifications.v1.NotificationService/ListNotifications';
const _seen =
    '/dzeroth.notifications.v1.NotificationService/MarkNotificationsSeen';
const _register =
    '/dzeroth.notifications.v1.NotificationService/RegisterDevice';

void main() {
  late AppDatabase db;
  late NotificationsStore store;
  late FakeTransport transport;
  late NotificationsRepository repo;
  late ServiceFeatureGate gate;
  late RateLimitHold hold;
  var flagOn = true;
  var disabledAsked = 0;

  late List<pb.ListNotificationsRequest> listRequests;
  late List<Object> answers;
  Object? seenAnswer;

  setUp(() {
    flagOn = true;
    disabledAsked = 0;
    listRequests = [];
    answers = [];
    seenAnswer = null;
    db = AppDatabase.forTesting(NativeDatabase.memory());
    store = NotificationsStore(db);
    gate = ServiceFeatureGate(
      isEnabled: () => flagOn,
      onDisabledByServer: () => disabledAsked++,
    );
    hold = RateLimitHold();
    transport = FakeTransport((procedure, input) async {
      if (procedure == _list) {
        listRequests.add(input as pb.ListNotificationsRequest);
        final next = answers.removeAt(0);
        if (next is Exception) throw next;
        return next;
      }
      if (procedure == _seen) {
        final a = seenAnswer;
        if (a is Exception) throw a;
        return a ?? pb.MarkNotificationsSeenResponse();
      }
      if (procedure == _register) return pb.RegisterDeviceResponse();
      throw StateError('unexpected $procedure');
    });
    repo = NotificationsRepository(
      apiClient: ApiClient.withTransport(transport),
      store: store,
      gate: gate,
      rateLimitHold: hold,
    );
  });
  tearDown(() => db.close());

  test('first open sends no token and caches rows with the tokens', () async {
    answers.add(
      listResponse(
        [notif('a', minutesAgo: 1), notif('b', minutesAgo: 5)],
        next: 'older',
        since: 's1',
        seenAt: kNotifBase.subtract(const Duration(hours: 1)),
      ),
    );

    final snapshot = await repo.refresh();

    expect(listRequests.single.sinceToken, isEmpty);
    expect(listRequests.single.pageToken, isEmpty);
    expect([for (final e in snapshot.entries) e.itemKey], ['a', 'b']);
    expect(snapshot.sinceToken, 's1');
    expect(snapshot.olderPageToken, 'older');
    expect(snapshot.seenAt, kNotifBase.subtract(const Duration(hours: 1)));
    // And the same from disk with no network call.
    final cached = await repo.cached();
    expect(cached.entries, hasLength(2));
    expect(listRequests, hasLength(1));
  });

  test('a refresh sends only since_token and replaces rows by id', () async {
    answers.add(
      listResponse([
        notif('like', minutesAgo: 30, actorCount: 1),
        notif('b', minutesAgo: 40),
      ], since: 's1'),
    );
    await repo.refresh();
    // The collapsed like is rewritten in place: same id, newer time, 3 actors.
    answers.add(
      listResponse([
        notif('like', minutesAgo: 1, actorCount: 3),
        notif('c', minutesAgo: 2),
      ], since: 's2'),
    );

    final snapshot = await repo.refresh();

    expect(listRequests.last.sinceToken, 's1');
    expect(listRequests.last.pageToken, isEmpty);
    expect([for (final e in snapshot.entries) e.itemKey], ['like', 'c', 'b']);
    expect(snapshot.entries.first.value!.actorCount, 3);
    expect(snapshot.sinceToken, 's2');
  });

  test(
    'a rejected since_token is dropped and exactly one cold open sent',
    () async {
      answers.add(listResponse([notif('a')], since: 's1'));
      await repo.refresh();
      answers
        ..add(rejectedToken('since_token'))
        ..add(listResponse([notif('b', minutesAgo: 0)], since: 's9'));

      final snapshot = await repo.refresh();

      expect(listRequests.map((r) => r.sinceToken), ['', 's1', '']);
      // The cold open replaces the cache: the old row is gone, only the
      // fresh page remains.
      expect(snapshot.sinceToken, 's9');
      expect(snapshot.entries.map((e) => e.itemKey), ['b']);
    },
  );

  test('a gap token persists a gap row and fillGap closes it', () async {
    answers.add(listResponse([notif('old', minutesAgo: 90)], since: 's1'));
    await repo.refresh();
    answers.add(
      listResponse(
        [notif('n2', minutesAgo: 1), notif('n1', minutesAgo: 2)],
        since: 's2',
        gap: 'gapTok',
      ),
    );

    var snapshot = await repo.refresh();

    final gap = snapshot.entries.where((e) => e.isGap).single;
    expect(gap.gapToken, 'gapTok');
    // The gap sits between the new rows and the old one.
    expect(snapshot.entries.map((e) => e.isGap ? 'gap' : e.itemKey), [
      'n2',
      'n1',
      'gap',
      'old',
    ]);

    answers.add(listResponse([notif('mid', minutesAgo: 30)]));
    snapshot = await repo.fillGap(gap.itemKey);

    expect(listRequests.last.pageToken, 'gapTok');
    expect(snapshot.entries.any((e) => e.isGap), isFalse);
    expect(snapshot.entries.map((e) => e.itemKey), ['n2', 'n1', 'mid', 'old']);
  });

  test('a refresh that returns no visible rows but a gap token keeps a gap '
      'above the newest cached row', () async {
    answers.add(
      listResponse([
        notif('a', minutesAgo: 1),
        notif('b', minutesAgo: 5),
      ], since: 's1'),
    );
    await repo.refresh();
    // Everything new was filtered (blocked/muted actors) but more exists.
    answers.add(listResponse(const [], since: 's2', gap: 'gapTok'));

    var snapshot = await repo.refresh();

    expect(snapshot.entries.map((e) => e.isGap ? 'gap' : e.itemKey), [
      'gap',
      'a',
      'b',
    ]);
    final gap = snapshot.entries.first;
    expect(gap.gapToken, 'gapTok');

    answers.add(listResponse([notif('mid', minutesAgo: 0)]));
    snapshot = await repo.fillGap(gap.itemKey);

    expect(listRequests.last.pageToken, 'gapTok');
    expect(snapshot.entries.map((e) => e.itemKey), ['mid', 'a', 'b']);
  });

  test(
    'existingDeviceId is read-only: nothing is generated or stored',
    () async {
      expect(await repo.existingDeviceId(), isEmpty);
      expect(await repo.existingDeviceId(), isEmpty);

      expect(await repo.deviceId(() => 'dev-1'), 'dev-1');
      expect(await repo.existingDeviceId(), 'dev-1');
    },
  );

  test('loadOlder keeps paging through empty filtered pages', () async {
    answers.add(
      listResponse([notif('a', minutesAgo: 1)], next: 'p1', since: 's'),
    );
    await repo.refresh();
    answers
      ..add(listResponse(const [], next: 'p2'))
      ..add(listResponse([notif('z', minutesAgo: 600)]));

    final snapshot = await repo.loadOlder();

    expect(listRequests.map((r) => r.pageToken), ['', 'p1', 'p2']);
    expect(snapshot.entries.map((e) => e.itemKey), ['a', 'z']);
    expect(snapshot.hasMore, isFalse);
  });

  test('flag off: no RPC at all', () async {
    flagOn = false;

    await expectLater(repo.refresh(), throwsA(isA<FeatureDisabledException>()));
    await expectLater(
      repo.markSeen('k'),
      throwsA(isA<FeatureDisabledException>()),
    );

    expect(transport.calledProcedures, isEmpty);
  });

  test('FEATURE_DISABLED from the server asks for one GetMe refresh', () async {
    answers.add(
      serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
      ),
    );

    await expectLater(repo.refresh(), throwsA(isA<FeatureDisabledException>()));

    expect(disabledAsked, 1);
    expect(repo.enabled, isFalse);
    gate.reset();
    expect(repo.enabled, isTrue);
  });

  test('a RATE_LIMITED list holds list calls but not mark-seen', () async {
    answers.add(
      serverError(
        connect.Code.resourceExhausted,
        common.ErrorReason.ERROR_REASON_RATE_LIMITED,
        metadata: {'limit': 'read_budget_daily'},
      ),
    );
    await expectLater(repo.refresh(), throwsA(isA<RateLimitedException>()));
    expect(repo.rateLimitedFor(), isNotNull);

    // A held list sends nothing.
    await expectLater(repo.refresh(), throwsA(isA<RateLimitedException>()));
    expect(listRequests, hasLength(1));

    // Mark-seen has its own cap and still goes out.
    seenAnswer = pb.MarkNotificationsSeenResponse();
    await repo.markSeen('k');
    expect(transport.calledProcedures, contains(_seen));
  });

  test('a mark-seen limit does not freeze list reads', () async {
    seenAnswer = serverError(
      connect.Code.resourceExhausted,
      common.ErrorReason.ERROR_REASON_RATE_LIMITED,
      metadata: {'limit': 'notification_seen_daily'},
    );
    await expectLater(repo.markSeen('k'), throwsA(isA<RateLimitedException>()));
    expect(repo.rateLimitedFor(), isNull);

    answers.add(listResponse([notif('a')], since: 's'));
    final snapshot = await repo.refresh();
    expect(snapshot.entries, hasLength(1));
  });

  test('markSeen stores the confirmed seen_at', () async {
    answers.add(listResponse([notif('a')], since: 's'));
    await repo.refresh();
    final seenAt = kNotifBase.add(const Duration(seconds: 5));
    seenAnswer = pb.MarkNotificationsSeenResponse(
      seenAt: listResponse(const [], seenAt: seenAt).seenAt,
    );

    final result = await repo.markSeen('key-1');

    expect(result, seenAt);
    expect((await repo.cached()).seenAt, seenAt);
  });

  test('registerDevice sends the platform and key', () async {
    await repo.registerDevice(
      idempotencyKey: 'k1',
      deviceId: 'dev-0123456789abcdef',
      fcmToken: 'tok',
      platform: DevicePlatform.DEVICE_PLATFORM_ANDROID,
    );
    expect(transport.calledProcedures, [_register]);
  });

  test('a write that started before sign-out never lands afterwards', () async {
    answers.add(listResponse([notif('a')], since: 's'));
    final session = store.session;
    db.sessionEpoch.end();
    await store.applyColdOpen(
      items: [notif('late')],
      sinceToken: 'x',
      nextPageToken: '',
      seenAt: null,
      session: session,
    );
    expect((await store.read()).entries, isEmpty);
  });
}
