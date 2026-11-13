import 'package:connectrpc/connect.dart' as connect;
import 'package:drift/native.dart';
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/notifications/data/notifications_repository.dart';
import 'package:dzeroth/features/notifications/data/notifications_store.dart';
import 'package:dzeroth/features/notifications/domain/notification_prefs.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/notifications/v1/notifications.pb.dart'
    as pb;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_transport.dart';
import '../../../support/posts_fixtures.dart';

const _get =
    '/dzeroth.notifications.v1.NotificationService/GetNotificationPrefs';
const _update =
    '/dzeroth.notifications.v1.NotificationService/UpdateNotificationPrefs';

void main() {
  late AppDatabase db;
  late FakeTransport transport;
  late NotificationsRepository repo;
  late ServiceFeatureGate gate;
  var flagOn = true;
  late List<Object> requests;
  Object? answer;

  setUp(() {
    flagOn = true;
    requests = [];
    answer = null;
    db = AppDatabase.forTesting(NativeDatabase.memory());
    gate = ServiceFeatureGate(isEnabled: () => flagOn);
    transport = FakeTransport((procedure, input) async {
      requests.add(input);
      final a = answer;
      if (a is Exception) throw a;
      if (procedure == _get) {
        return a ??
            pb.GetNotificationPrefsResponse(
              prefs: pb.NotificationPrefs(
                plansPush: true,
                mentionsRepliesPush: false,
                likesRepostsPush: true,
                followersPush: true,
                messagesPush: false,
              ),
            );
      }
      if (procedure == _update) {
        final request = input as pb.UpdateNotificationPrefsRequest;
        return a ?? pb.UpdateNotificationPrefsResponse(prefs: request.prefs);
      }
      throw StateError('unexpected $procedure');
    });
    repo = NotificationsRepository(
      apiClient: ApiClient.withTransport(transport),
      store: NotificationsStore(db),
      gate: gate,
    );
  });
  tearDown(() => db.close());

  test('get maps every group of the server answer', () async {
    final prefs = await repo.getPushPrefs();
    expect(
      prefs,
      const NotificationPushPrefs(
        plans: true,
        mentionsReplies: false,
        likesReposts: true,
        followers: true,
        messages: false,
      ),
    );
    expect(transport.calledProcedures, [_get]);
  });

  test(
    'update sends every group and the key, returns the server copy',
    () async {
      const target = NotificationPushPrefs(
        plans: false,
        mentionsReplies: true,
        likesReposts: false,
        followers: true,
        messages: true,
      );
      final saved = await repo.updatePushPrefs(
        idempotencyKey: 'key-0123456789abcdef',
        prefs: target,
      );
      final sent = requests.single as pb.UpdateNotificationPrefsRequest;
      expect(sent.idempotencyKey, 'key-0123456789abcdef');
      expect(sent.hasPrefs(), isTrue);
      expect(sent.prefs.plansPush, isFalse);
      expect(sent.prefs.mentionsRepliesPush, isTrue);
      expect(sent.prefs.likesRepostsPush, isFalse);
      expect(sent.prefs.followersPush, isTrue);
      expect(sent.prefs.messagesPush, isTrue);
      expect(saved, target);
    },
  );

  test('with the notifications gate closed no RPC is sent', () async {
    flagOn = false;
    await expectLater(
      repo.getPushPrefs(),
      throwsA(isA<FeatureDisabledException>()),
    );
    await expectLater(
      repo.updatePushPrefs(
        idempotencyKey: 'key-0123456789abcdef',
        prefs: const NotificationPushPrefs(
          plans: true,
          mentionsReplies: true,
          likesReposts: true,
          followers: true,
          messages: true,
        ),
      ),
      throwsA(isA<FeatureDisabledException>()),
    );
    expect(transport.calledProcedures, isEmpty);
  });

  test(
    'FEATURE_DISABLED notification_prefs never closes the notifications gate',
    () async {
      answer = serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        metadata: {'feature': 'notification_prefs'},
      );
      await expectLater(
        repo.getPushPrefs(),
        throwsA(
          isA<FeatureDisabledException>().having(
            (e) => e.feature,
            'feature',
            'notification_prefs',
          ),
        ),
      );
      // The list and the badge keep working.
      expect(gate.enabled, isTrue);
    },
  );
}
