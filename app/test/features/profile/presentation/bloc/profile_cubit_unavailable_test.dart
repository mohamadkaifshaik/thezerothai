import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/session/user_ids.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/profile/presentation/bloc/profile_cubit.dart';
import 'package:dzeroth/features/profile/presentation/bloc/profile_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockIdentity extends Mock implements IdentityRepository {}

class _MockGraph extends Mock implements GraphRepository {}

void main() {
  blocTest<ProfileCubit, ProfileState>(
    'a link to the tombstone id is "not found" without asking the server',
    build: () => ProfileCubit(
      identityRepository: _MockIdentity(),
      graphRepository: _MockGraph(),
      userId: kUnavailableUserId,
      graphEnabled: true,
      ownUserId: 'u0abcdefghijklmnopqrstuvw2',
    ),
    act: (cubit) => cubit.load(),
    expect: () => [
      isA<ProfileState>().having(
        (s) => s.status,
        'status',
        ProfileStatus.notFound,
      ),
    ],
  );
}
