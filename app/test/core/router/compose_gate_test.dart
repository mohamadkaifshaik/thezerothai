import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/router/compose_gate.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

void main() {
  Future<bool> gate(
    WidgetTester tester, {
    required Set<String> flags,
    required String location,
  }) async {
    final bloc = MockOnboardingBloc();
    whenListen(
      bloc,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(enabledFeatures: flags),
    );
    late bool result;
    await tester.pumpWidget(
      BlocProvider<OnboardingBloc>.value(
        value: bloc,
        child: Builder(
          builder: (context) {
            result = canComposeAt(context, location);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return result;
  }

  testWidgets('offered with the posts flag on, on Home and on a profile', (
    tester,
  ) async {
    expect(await gate(tester, flags: {'posts'}, location: '/home'), isTrue);
    expect(
      await gate(tester, flags: {'posts'}, location: '/profile/ada'),
      isTrue,
    );
  });

  testWidgets('not offered with the posts flag off', (tester) async {
    expect(await gate(tester, flags: {}, location: '/home'), isFalse);
  });

  testWidgets('not offered on Settings, including its sub-pages', (
    tester,
  ) async {
    expect(
      await gate(tester, flags: {'posts'}, location: '/settings'),
      isFalse,
    );
    expect(
      await gate(tester, flags: {'posts'}, location: '/settings/profile'),
      isFalse,
    );
  });
}
