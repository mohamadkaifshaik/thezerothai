import 'package:flutter/foundation.dart' show FlutterError, FlutterErrorDetails;

import '../core/storage/app_database.dart';
import '../features/onboarding/presentation/bloc/onboarding_bloc.dart';
import '../features/onboarding/presentation/bloc/onboarding_event.dart';
import '../features/posts/domain/posts_feature_flag.dart';
import '../features/timeline/data/timeline_repository.dart';

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

/// Reports an unexpected (non-user) error. One shared hook, wired from
/// bootstrap into every cubit that wants Crashlytics non-fatals. For now it
/// goes through [FlutterError.reportError] (the Crashlytics handler hooks it).
typedef UnexpectedErrorReporter = void Function(Object error, StackTrace stack);

void reportUnexpectedError(Object error, StackTrace stack) {
  FlutterError.reportError(
    FlutterErrorDetails(exception: error, stack: stack, library: 'dzeroth'),
  );
}

/// Sign-out: end the shared session epoch first (timeline, graph and
/// identity writes of in-flight requests are then dropped) and clear the
/// timeline's in-flight work, then wipe the
/// local cache in one transaction, so nothing of the previous user survives
/// or is written back (privacy: CLAUDE.md rule 10).
Future<void> wipeSessionData({
  required AppDatabase database,
  required TimelineRepository timelineRepository,
}) async {
  // Ends the shared SessionEpoch and forgets in-flight and queued timeline
  // work (a new user must never be handed the old user's future).
  // End the epoch here directly, so a wipe path can never leave graph and
  // identity writes unguarded; clearSession then drops the timeline's
  // in-flight maps (it ends the epoch again, which is harmless).
  database.sessionEpoch.end();
  timelineRepository.clearSession();
  await database.clearAll();
}
