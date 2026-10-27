import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/profile/presentation/bloc/profile_cubit.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockIdentityRepository extends Mock implements IdentityRepository {}

class _MockGraphRepository extends Mock implements GraphRepository {}

/// W3-17: what the profile header keeps in step with the pin.
void main() {
  late _MockIdentityRepository identityRepository;

  setUp(() {
    identityRepository = _MockIdentityRepository();
  });

  Future<ProfileCubit> loaded({String pin = '42', int posts = 3}) async {
    when(() => identityRepository.getProfile(handle: 'kaif')).thenAnswer(
      (_) async => identity.Profile(
        userId: 'me',
        handle: 'kaif',
        postsCount: Int64(posts),
        pinnedPostId: pin,
      ),
    );
    final cubit = ProfileCubit(
      identityRepository: identityRepository,
      graphRepository: _MockGraphRepository(),
      handle: 'kaif',
      graphEnabled: false,
      ownUserId: 'me',
    );
    addTearDown(cubit.close);
    await cubit.load();
    return cubit;
  }

  test(
    'deleting the pinned post drops the pin and one from the count',
    () async {
      final cubit = await loaded();

      cubit.pinnedPostDeleted();

      expect(cubit.state.profile!.pinnedPostId, '');
      expect(cubit.state.profile!.postsCount, Int64(2));
    },
  );

  test('the count never goes below zero', () async {
    final cubit = await loaded(posts: 0);

    cubit.pinnedPostDeleted();

    expect(cubit.state.profile!.postsCount, Int64.ZERO);
    expect(cubit.state.profile!.pinnedPostId, '');
  });

  test('before the profile loaded it does nothing', () {
    final cubit = ProfileCubit(
      identityRepository: identityRepository,
      graphRepository: _MockGraphRepository(),
      handle: 'kaif',
      graphEnabled: false,
      ownUserId: 'me',
    );
    addTearDown(cubit.close);

    cubit.pinnedPostDeleted();

    expect(cubit.state.profile, isNull);
  });

  test('profileUpdated carries a new pin to the state', () async {
    final cubit = await loaded(pin: '');

    cubit.profileUpdated(
      identity.Profile(userId: 'me', handle: 'kaif', pinnedPostId: '7'),
    );

    expect(cubit.state.profile!.pinnedPostId, '7');
  });
}
