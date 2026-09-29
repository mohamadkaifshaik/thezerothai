import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/features/graph/presentation/graph_feature_flags.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

void main() {
  late MockOnboardingBloc onboardingBloc;

  setUp(() {
    onboardingBloc = MockOnboardingBloc();
  });

  Widget wrap(Widget Function(BuildContext) builder) {
    return BlocProvider<OnboardingBloc>.value(
      value: onboardingBloc,
      child: MaterialApp(home: Builder(builder: builder)),
    );
  }

  testWidgets('isGraphEnabled is false when enabledFeatures is empty', (
    tester,
  ) async {
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: const OnboardingState(),
    );
    bool? result;
    await tester.pumpWidget(
      wrap((context) {
        result = isGraphEnabled(context);
        return const SizedBox.shrink();
      }),
    );

    expect(result, isFalse);
  });

  testWidgets('isGraphEnabled is true when enabledFeatures contains "graph"', (
    tester,
  ) async {
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: const OnboardingState(enabledFeatures: {'graph'}),
    );
    bool? result;
    await tester.pumpWidget(
      wrap((context) {
        result = isGraphEnabled(context);
        return const SizedBox.shrink();
      }),
    );

    expect(result, isTrue);
  });

  testWidgets('an unknown flag name is ignored', (tester) async {
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: const OnboardingState(enabledFeatures: {'some_other_flag'}),
    );
    bool? result;
    await tester.pumpWidget(
      wrap((context) {
        result = isGraphEnabled(context);
        return const SizedBox.shrink();
      }),
    );

    expect(result, isFalse);
  });
}
