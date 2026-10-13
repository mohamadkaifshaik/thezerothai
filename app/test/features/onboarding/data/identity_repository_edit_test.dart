import 'package:connectrpc/connect.dart' as connect;
import 'package:drift/native.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_transport.dart';
import '../../../support/posts_fixtures.dart';

const _update = '/dzeroth.identity.v1.IdentityService/UpdateProfile';
const _change = '/dzeroth.identity.v1.IdentityService/ChangeHandle';

void main() {
  late AppDatabase db;
  late FakeTransport transport;
  late IdentityRepository repo;
  late List<Object> requests;
  late Object Function(String procedure) answer;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    requests = [];
    answer = (_) => throw StateError('unscripted');
    transport = FakeTransport((procedure, input) async {
      requests.add(input);
      final r = answer(procedure);
      if (r is Exception) throw r;
      return r;
    });
    repo = IdentityRepository(
      apiClient: ApiClient.withTransport(transport),
      database: db,
    );
  });

  tearDown(() => db.close());

  identity.Profile profile({String handle = 'kaif', String name = 'Kaif'}) =>
      identity.Profile(userId: 'me', handle: handle, displayName: name);

  test(
    'updateProfile sends only the given fields and caches the result',
    () async {
      answer = (_) =>
          identity.UpdateProfileResponse(profile: profile(name: 'Kaif S'));

      final result = await repo.updateProfile(
        idempotencyKey: 'key-1234567890abcdef',
        displayName: 'Kaif S',
      );

      final sent = requests.single as identity.UpdateProfileRequest;
      expect(sent.idempotencyKey, 'key-1234567890abcdef');
      expect(sent.hasDisplayName(), isTrue);
      expect(sent.displayName, 'Kaif S');
      expect(sent.hasBio(), isFalse);
      expect(sent.hasAvatarMediaId(), isFalse);
      expect(sent.hasIsPrivate(), isFalse);
      expect(transport.calledProcedures, [_update]);
      expect(result.displayName, 'Kaif S');
      expect((await repo.cachedOwnProfile('me'))!.displayName, 'Kaif S');
    },
  );

  test('changeHandle sends the new handle and caches the result', () async {
    answer = (_) =>
        identity.ChangeHandleResponse(profile: profile(handle: 'new_one'));

    final result = await repo.changeHandle(
      idempotencyKey: 'key-1234567890abcdef',
      newHandle: 'new_one',
    );

    final sent = requests.single as identity.ChangeHandleRequest;
    expect(sent.newHandle, 'new_one');
    expect(transport.calledProcedures, [_change]);
    expect(result.handle, 'new_one');
    expect((await repo.cachedOwnProfile('me'))!.handle, 'new_one');
  });

  test(
    'the handle cooldown surfaces as LimitReached with the time left',
    () async {
      answer = (_) => serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_LIMIT_REACHED,
        metadata: {'quota': 'handle_change'},
      );

      await expectLater(
        repo.changeHandle(
          idempotencyKey: 'key-1234567890abcdef',
          newHandle: 'x_y',
        ),
        throwsA(
          isA<LimitReachedException>().having(
            (e) => e.quota,
            'quota',
            'handle_change',
          ),
        ),
      );
    },
  );

  group('a sign-out during the RPC drops the cache write', () {
    test('updateProfile', () async {
      answer = (_) {
        db.sessionEpoch.end();
        return identity.UpdateProfileResponse(profile: profile(name: 'Late'));
      };

      final result = await repo.updateProfile(
        idempotencyKey: 'key-1234567890abcdef',
        displayName: 'Late',
      );

      // The caller still gets the server's answer; the next user's cache
      // never sees it.
      expect(result.displayName, 'Late');
      expect(await repo.cachedOwnProfile('me'), isNull);
    });

    test('changeHandle', () async {
      answer = (_) {
        db.sessionEpoch.end();
        return identity.ChangeHandleResponse(profile: profile(handle: 'late'));
      };

      final result = await repo.changeHandle(
        idempotencyKey: 'key-1234567890abcdef',
        newHandle: 'late',
      );

      expect(result.handle, 'late');
      expect(await repo.cachedOwnProfile('me'), isNull);
    });
  });
}
