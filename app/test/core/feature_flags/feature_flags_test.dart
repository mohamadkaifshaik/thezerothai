import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/feature_flags/feature_flags.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/domain/posts_feature_flag.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

void main() {
  late MockOnboardingBloc bloc;

  setUp(() => bloc = MockOnboardingBloc());

  Future<bool?> read(
    WidgetTester tester,
    Set<String> features,
    String name,
  ) async {
    whenListen(
      bloc,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(enabledFeatures: features),
    );
    bool? result;
    await tester.pumpWidget(
      BlocProvider<OnboardingBloc>.value(
        value: bloc,
        child: MaterialApp(
          home: Builder(
            builder: (context) {
              result = isFeatureEnabled(context, name);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    return result;
  }

  testWidgets('kFeaturePosts is "posts" and off when absent', (tester) async {
    expect(kFeaturePosts, 'posts');
    expect(await read(tester, {}, kFeaturePosts), isFalse);
  });

  testWidgets('is on only for the named flag', (tester) async {
    expect(await read(tester, {'posts'}, kFeaturePosts), isTrue);
    expect(await read(tester, {'graph'}, kFeaturePosts), isFalse);
  });
}
