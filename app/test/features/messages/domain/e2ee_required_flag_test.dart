import 'dart:async';

import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

// Plan 6 Task 1.B, security review L1: the one `e2ee_required` reader fails
// closed while the flag set is not known and while the state is another
// user's.

class _MockIdentity extends Mock implements IdentityRepository {}

AppUser _user(String uid) => AppUser(
  uid: uid,
  email: '$uid@example.com',
  emailVerified: true,
  isPasswordProvider: true,
);

void main() {
  group('e2eeRequiredFor', () {
    const known = OnboardingState(status: OnboardingStatus.ready);

    test('a known flag set of the signed-in user decides', () {
      expect(e2eeRequiredFor(known, stateUid: 'a', signedInUid: 'a'), isFalse);
      expect(
        e2eeRequiredFor(
          known.copyWith(enabledFeatures: {kFeatureE2eeRequired}),
          stateUid: 'a',
          signedInUid: 'a',
        ),
        isTrue,
      );
    });

    test('featuresPending answers required (fails closed)', () {
      for (final s in [
        const OnboardingState(),
        const OnboardingState(status: OnboardingStatus.loading),
        known.copyWith(flagsPending: true),
      ]) {
        expect(s.featuresPending, isTrue);
        expect(
          e2eeRequiredFor(s, stateUid: 'a', signedInUid: 'a'),
          isTrue,
          reason: '$s',
        );
      }
    });

    test('a state of another user answers required (fails closed)', () {
      for (final (stateUid, signedIn) in [
        ('a', 'b'),
        (null, 'b'),
        ('a', null),
      ]) {
        expect(
          e2eeRequiredFor(known, stateUid: stateUid, signedInUid: signedIn),
          isTrue,
          reason: '$stateUid vs $signedIn',
        );
      }
    });
  });

  group('e2eeRequiredOf over a real OnboardingBloc', () {
    late _MockIdentity identityRepository;
    late Completer<identity.GetMeResponse> getMe;

    setUp(() {
      identityRepository = _MockIdentity();
      when(() => identityRepository.cachedOwnProfile(any()))
          .thenAnswer((_) async => null);
      getMe = Completer();
      when(() => identityRepository.getMe()).thenAnswer((_) => getMe.future);
    });

    test('required while GetMe has not answered, then the flag set decides, '
        'and again while the bloc moves to another user', () async {
      final bloc = OnboardingBloc(identityRepository: identityRepository);
      addTearDown(bloc.close);
      final required = e2eeRequiredOf(bloc);
      expect(required(), isTrue, reason: 'no user, no flags');

      bloc.add(OnboardingUserAuthenticated(_user('a')));
      await pumpEventQueue();
      expect(bloc.state.featuresPending, isTrue);
      expect(required(), isTrue, reason: 'GetMe pending');

      getMe.complete(
        identity.GetMeResponse(
          profile: identity.Profile(userId: 'a', handle: 'a'),
          enabledFeatures: ['messaging'],
        ),
      );
      await pumpEventQueue();
      expect(bloc.state.featuresPending, isFalse);
      expect(required(), isFalse, reason: 'known, without e2ee_required');

      // The auth user is already b; the bloc still holds a's state.
      var authUid = 'b';
      final viaAuth = e2eeRequiredOf(bloc, signedInUid: () => authUid);
      expect(viaAuth(), isTrue, reason: "a's flags while b is signed in");
      authUid = 'a';
      expect(viaAuth(), isFalse);

      // The bloc itself moves to b before b's GetMe answers.
      getMe = Completer();
      bloc.add(OnboardingUserAuthenticated(_user('b')));
      await pumpEventQueue();
      expect(bloc.currentUid, 'b');
      expect(required(), isTrue, reason: "b's flags are not known yet");
    });
  });
}
