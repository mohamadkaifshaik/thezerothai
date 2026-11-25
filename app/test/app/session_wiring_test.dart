import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../support/posts_fixtures.dart';

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

void main() {
  setUpAll(() => registerFallbackValue(const OnboardingRefreshRequested()));

  test('whole-service FEATURE_DISABLED refreshes GetMe; the next successful '
      'GetMe resets the gate', () async {
    final bloc = MockOnboardingBloc();
    final states = StreamController<OnboardingState>.broadcast();
    whenListen(
      bloc,
      states.stream,
      initialState: OnboardingState(enabledFeatures: {'posts'}),
    );
    var generation = 0;
    when(() => bloc.flagsGeneration).thenAnswer((_) => generation);

    final gate = buildPostsGate(bloc);
    expect(gate.postsEnabled, isTrue);

    await expectLater(
      gate.run<void>(
        () async => throw serverError(
          connect.Code.failedPrecondition,
          common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        ),
      ),
      throwsA(isA<FeatureDisabledException>()),
    );
    expect(gate.postsEnabled, isFalse);
    final event = verify(() => bloc.add(captureAny())).captured.single;
    expect(event, isA<OnboardingRefreshRequested>());

    // A state change that is not a GetMe answer (security L-new-1): the
    // gate keeps what the server said. The freezed getter wraps the set on
    // every read, so identity could never tell the two apart.
    states.add(
      OnboardingState(enabledFeatures: {'posts'}, pendingFollowRequestCount: 1),
    );
    await Future<void>.delayed(Duration.zero);
    expect(gate.postsEnabled, isFalse, reason: 'not a GetMe answer');

    // GetMe succeeds with an equal flag set: the generation moved, so the
    // gate resets.
    generation++;
    states.add(OnboardingState(enabledFeatures: {'posts'}));
    await Future<void>.delayed(Duration.zero);
    expect(gate.postsEnabled, isTrue);
    await states.close();
  });

  test('a sub-feature disable does not refresh GetMe', () async {
    final bloc = MockOnboardingBloc();
    whenListen(
      bloc,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(enabledFeatures: {'posts'}),
    );
    when(() => bloc.flagsGeneration).thenReturn(0);
    final gate = buildPostsGate(bloc);
    await expectLater(
      gate.run<void>(
        () async => throw serverError(
          connect.Code.failedPrecondition,
          common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
          metadata: {'feature': 'media'},
        ),
      ),
      throwsA(isA<FeatureDisabledException>()),
    );
    verifyNever(() => bloc.add(any()));
    expect(gate.postsEnabled, isTrue);
  });
}
