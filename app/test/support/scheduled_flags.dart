import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/domain/posts_feature_flag.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// The Scheduled list's two flag modes: `posts` alone (a caller dropped from
/// the `scheduled_posts` allowlist: Cancel and Dismiss only) and with
/// `scheduled_posts` (Edit and Post now too).
const kScheduledListOnly = <String>{kFeaturePosts};
const kScheduledActions = <String>{kFeaturePosts, kFeatureScheduledPosts};

/// An [OnboardingBloc] that is ready with [flags] on.
OnboardingBloc onboardingWithFlags(Set<String> flags) {
  final bloc = _MockOnboardingBloc();
  whenListen(
    bloc,
    const Stream<OnboardingState>.empty(),
    initialState: OnboardingState(
      status: OnboardingStatus.ready,
      enabledFeatures: flags,
    ),
  );
  return bloc;
}
