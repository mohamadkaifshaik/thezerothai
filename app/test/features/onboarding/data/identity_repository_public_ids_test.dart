import 'package:connectrpc/connect.dart' as connect;
import 'package:drift/native.dart';
import 'package:dzeroth/core/feature_flags/public_ids_feature_flag.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/session/user_ids.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_transport.dart';

const _firebaseUid = 'q7Zk3mV9aXb2LcD8eF1gH4iJ5kL6';
const _publicId = 'u0abcdefghijklmnopqrstuvw2';

/// The own-profile cache is keyed by the user id the server sent, which is the
/// public id once `public_ids` is on; the warm start must still find it from
/// the Firebase uid the app signs in with.
void main() {
  late AppDatabase db;
  late bool offline;
  late String sentId;
  late Set<String> flags;
  late IdentityRepository repo;

  const user = AppUser(
    uid: _firebaseUid,
    emailVerified: true,
    isPasswordProvider: true,
  );

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.claimCacheFor(_firebaseUid);
    offline = false;
    sentId = _publicId;
    flags = {kFeaturePublicIds};
    repo = IdentityRepository(
      apiClient: ApiClient.withTransport(
        FakeTransport((procedure, input) async {
          if (offline) {
            throw connect.ConnectException(
              connect.Code.unavailable,
              'no network',
            );
          }
          return identity.GetMeResponse(
            profile: identity.Profile(
              userId: sentId,
              handle: 'kaif',
              displayName: 'Kaif',
            ),
            enabledFeatures: flags,
          );
        }),
      ),
      database: db,
    );
  });

  tearDown(() => db.close());

  test(
    'before any GetMe the row can only be keyed by the Firebase uid',
    () async {
      expect(await repo.cachedOwnProfile(_firebaseUid), isNull);
    },
  );

  test('public_ids on: GetMe caches under the public id and the Firebase uid '
      'still finds it', () async {
    await repo.getMe();

    final cached = await repo.cachedOwnProfile(_firebaseUid);
    expect(cached, isNotNull);
    expect(cached!.userId, _publicId);
    expect(await db.profileByUserId(_firebaseUid), isNull);
  });

  test('public_ids off: unchanged, the row is the Firebase uid', () async {
    sentId = _firebaseUid;
    flags = {};
    await repo.getMe();

    expect((await repo.cachedOwnProfile(_firebaseUid))!.userId, _firebaseUid);
  });

  test('a warm start with the flag on: ready from the cache, flags pending; '
      'an offline GetMe keeps the app usable with the public id', () async {
    await repo.getMe();
    offline = true;
    final bloc = OnboardingBloc(identityRepository: repo);
    addTearDown(bloc.close);
    final states = <OnboardingState>[];
    final sub = bloc.stream.listen(states.add);
    addTearDown(sub.cancel);

    bloc.add(const OnboardingUserAuthenticated(user));
    await bloc.stream.firstWhere((s) => s.refreshFailed);

    final cachedRender = states.first;
    expect(cachedRender.status, OnboardingStatus.ready);
    expect(cachedRender.flagsPending, isTrue);
    expect(cachedRender.profile?.userId, _publicId);
    expect(cachedRender.myUserId, isNull, reason: 'GetMe has not answered');
    expect(bloc.state.status, OnboardingStatus.ready);
    expect(bloc.state.profile?.userId, _publicId);
  });

  test('a warm start after the id kind flipped: the stale row is not used, '
      'GetMe decides', () async {
    sentId = _firebaseUid;
    flags = {};
    await repo.getMe();
    // Rolled out: the next GetMe answers a public id.
    sentId = _publicId;
    flags = {kFeaturePublicIds};
    await repo.getMe();

    final bloc = OnboardingBloc(identityRepository: repo);
    addTearDown(bloc.close);
    bloc.add(const OnboardingUserAuthenticated(user));
    final ready = await bloc.stream.firstWhere((s) => !s.flagsPending);

    expect(ready.myUserId, _publicId);
    expect(ready.enabledFeatures, contains(kFeaturePublicIds));
  });
}
