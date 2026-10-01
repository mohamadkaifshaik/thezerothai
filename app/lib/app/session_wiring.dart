import '../core/storage/app_database.dart';
import '../features/onboarding/presentation/bloc/onboarding_bloc.dart';
import '../features/onboarding/presentation/bloc/onboarding_event.dart';
import '../features/posts/domain/posts_feature_flag.dart';

/// Builds the posts flag gate wired to [onboardingBloc] (ADR-0010 D1/D2):
///
/// - enabled iff `GetMe.enabled_features` contains `posts`;
/// - FEATURE_DISABLED with no feature named dispatches
///   [OnboardingRefreshRequested] (ADR-0008 D6), so a fresh `GetMe` decides;
/// - every successful `GetMe` (it emits a new flag-set instance) resets what
///   earlier FEATURE_DISABLED answers taught the gate, so a whole-service
///   disable can never stick for the session.
PostsFeatureGate buildPostsGate(OnboardingBloc onboardingBloc) {
  final gate = PostsFeatureGate(
    isPostsEnabled: () =>
        onboardingBloc.state.enabledFeatures.contains(kFeaturePosts),
    onWholeServiceDisabled: () =>
        onboardingBloc.add(const OnboardingRefreshRequested()),
  );
  var last = onboardingBloc.state.enabledFeatures;
  onboardingBloc.stream.listen((state) {
    if (!identical(state.enabledFeatures, last)) {
      last = state.enabledFeatures;
      gate.reset();
    }
  });
  return gate;
}

/// Sign-out: end the shared session epoch first (timeline, graph and
/// identity writes of in-flight requests are then dropped), then wipe the
/// local cache in one transaction, so nothing of the previous user survives
/// or is written back (privacy: CLAUDE.md rule 10).
Future<void> wipeSessionData({required AppDatabase database}) async {
  database.sessionEpoch.end();
  await database.clearAll();
}
