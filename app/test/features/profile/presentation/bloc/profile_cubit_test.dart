import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/profile/presentation/bloc/profile_cubit.dart';
import 'package:dzeroth/features/profile/presentation/bloc/profile_state.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockIdentityRepository extends Mock implements IdentityRepository {}

class MockGraphRepository extends Mock implements GraphRepository {}

void main() {
  late MockIdentityRepository identityRepository;
  late MockGraphRepository graphRepository;

  setUp(() {
    identityRepository = MockIdentityRepository();
    graphRepository = MockGraphRepository();
  });

  ProfileCubit buildCubit({required bool graphEnabled, String? ownUserId}) {
    return ProfileCubit(
      identityRepository: identityRepository,
      graphRepository: graphRepository,
      handle: 'kaif',
      graphEnabled: graphEnabled,
      ownUserId: ownUserId,
    );
  }

  blocTest<ProfileCubit, ProfileState>(
    'loads the profile and the relationship when the flag is on and it is '
    "not the viewer's own profile",
    build: () {
      when(() => identityRepository.getProfile(handle: 'kaif')).thenAnswer(
        (_) async => identity.Profile(userId: 'target-uid', handle: 'kaif'),
      );
      when(() => graphRepository.cached('target-uid')).thenReturn(null);
      when(() => graphRepository.relationshipFor('target-uid')).thenAnswer(
        (_) async => graph.Relationship(
          userId: 'target-uid',
          followState: graph.FollowState.FOLLOW_STATE_FOLLOWING,
        ),
      );
      return buildCubit(graphEnabled: true, ownUserId: 'viewer-uid');
    },
    act: (cubit) => cubit.load(),
    expect: () => [
      isA<ProfileState>().having(
        (s) => s.status,
        'status',
        ProfileStatus.loading,
      ),
      isA<ProfileState>()
          .having((s) => s.status, 'status', ProfileStatus.ready)
          .having((s) => s.isOwnProfile, 'isOwnProfile', false)
          .having(
            (s) => s.relationship?.followState,
            'relationship.followState',
            graph.FollowState.FOLLOW_STATE_FOLLOWING,
          ),
    ],
  );

  blocTest<ProfileCubit, ProfileState>(
    'never fetches a relationship for the own profile',
    build: () {
      when(() => identityRepository.getProfile(handle: 'kaif')).thenAnswer(
        (_) async => identity.Profile(userId: 'viewer-uid', handle: 'kaif'),
      );
      return buildCubit(graphEnabled: true, ownUserId: 'viewer-uid');
    },
    act: (cubit) => cubit.load(),
    expect: () => [
      isA<ProfileState>(),
      isA<ProfileState>()
          .having((s) => s.status, 'status', ProfileStatus.ready)
          .having((s) => s.isOwnProfile, 'isOwnProfile', true)
          .having((s) => s.relationship, 'relationship', isNull),
    ],
    verify: (_) {
      verifyNever(() => graphRepository.relationshipFor(any()));
    },
  );

  blocTest<ProfileCubit, ProfileState>(
    'never fetches a relationship when the graph flag is off',
    build: () {
      when(() => identityRepository.getProfile(handle: 'kaif')).thenAnswer(
        (_) async => identity.Profile(userId: 'target-uid', handle: 'kaif'),
      );
      when(() => graphRepository.cached('target-uid')).thenReturn(null);
      return buildCubit(graphEnabled: false, ownUserId: 'viewer-uid');
    },
    act: (cubit) => cubit.load(),
    expect: () => [
      isA<ProfileState>(),
      isA<ProfileState>()
          .having((s) => s.status, 'status', ProfileStatus.ready)
          .having((s) => s.relationship, 'relationship', isNull),
    ],
    verify: (_) {
      verifyNever(() => graphRepository.relationshipFor(any()));
    },
  );

  blocTest<ProfileCubit, ProfileState>(
    'goes to notFound on NotFoundException (missing or blocked-by, '
    'byte-identical per ADR-0008 D9)',
    build: () {
      when(() => identityRepository.getProfile(handle: 'kaif'))
          .thenThrow(const NotFoundException("doesn't matter which"));
      return buildCubit(graphEnabled: true, ownUserId: 'viewer-uid');
    },
    act: (cubit) => cubit.load(),
    expect: () => [
      isA<ProfileState>().having(
        (s) => s.status,
        'status',
        ProfileStatus.loading,
      ),
      const ProfileState(status: ProfileStatus.notFound),
    ],
  );

  blocTest<ProfileCubit, ProfileState>(
    'shows the profile even if fetching the relationship fails',
    build: () {
      when(() => identityRepository.getProfile(handle: 'kaif')).thenAnswer(
        (_) async => identity.Profile(userId: 'target-uid', handle: 'kaif'),
      );
      when(() => graphRepository.cached('target-uid')).thenReturn(null);
      when(() => graphRepository.relationshipFor('target-uid'))
          .thenThrow(const NetworkException('offline'));
      return buildCubit(graphEnabled: true, ownUserId: 'viewer-uid');
    },
    act: (cubit) => cubit.load(),
    expect: () => [
      isA<ProfileState>(),
      isA<ProfileState>()
          .having((s) => s.status, 'status', ProfileStatus.ready)
          .having((s) => s.relationship, 'relationship', isNull),
    ],
  );
}
