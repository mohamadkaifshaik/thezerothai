import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/search/presentation/widgets/app_search_field.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../support/fake_search_repository.dart';
import '../../../support/search_field_rig.dart';

class _MockAuth extends MockBloc<AuthEvent, AuthState> implements AuthBloc {}

class _RecordingStore extends FakeRecentSearchesStore {
  final List<String> reads = [];

  @override
  Future<List<String>> read(String uid) {
    reads.add(uid);
    return super.read(uid);
  }
}

/// Recent searches are device storage of the signed-in account: keyed by the
/// Firebase uid, never by the server-issued user id (which changes kind when
/// `public_ids` flips, and the list would be lost).
void main() {
  testWidgets('the recent searches are read under the Firebase uid, not '
      'the API user id', (tester) async {
    const firebaseUid = 'q7Zk3mV9aXb2LcD8eF1gH4iJ5kL6';
    final auth = _MockAuth();
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(
        status: AuthStatus.authenticated,
        user: AppUser(
          uid: firebaseUid,
          emailVerified: true,
          isPasswordProvider: true,
        ),
      ),
    );
    final store = _RecordingStore();

    final onboarding = await pumpWithSearch(
      tester,
      BlocProvider<AuthBloc>.value(value: auth, child: const AppSearchField()),
      repository: FakeSearchRepository(),
      store: store,
    );
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: const {'search', 'trends'},
        profile: identity.Profile(userId: 'u0abcdefghijklmnopqrstuvw2'),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.pump();

    expect(store.reads, isNotEmpty);
    expect(store.reads.toSet(), {firebaseUid});
  });
}
