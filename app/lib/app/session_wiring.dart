import 'dart:async';

import 'package:flutter/foundation.dart' show FlutterError, FlutterErrorDetails;

import '../core/feature_flags/service_feature_gate.dart';
import '../core/storage/app_database.dart';
import '../features/auth/domain/app_user.dart';
import '../features/auth/presentation/bloc/auth_state.dart';
import '../features/messages/data/messaging_repository.dart';
import '../features/messages/domain/messaging_feature_gate.dart';
import '../features/messages/domain/messaging_feature_flag.dart';
import '../features/onboarding/presentation/bloc/onboarding_bloc.dart';
import '../features/onboarding/presentation/bloc/onboarding_event.dart';
import '../features/posts/domain/posts_feature_flag.dart';
import '../features/notifications/data/notifications_repository.dart';
import '../features/timeline/data/timeline_repository.dart';

/// Resets [gate] on every fresh `GetMe` (it emits a new flag-set instance),
/// so a remembered FEATURE_DISABLED can never stick for the session.
void _wireGateReset(OnboardingBloc onboardingBloc, ServiceFeatureGate gate) {
  var last = onboardingBloc.state.enabledFeatures;
  onboardingBloc.stream.listen((state) {
    if (!identical(state.enabledFeatures, last)) {
      last = state.enabledFeatures;
      gate.reset();
    }
  });
}

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
  _wireGateReset(onboardingBloc, gate);
  return gate;
}

/// Builds the gate of one whole-service flag ([flagName]: `notifications`,
/// `reports`) wired to [onboardingBloc], the same way [buildPostsGate] is:
///
/// - enabled iff `GetMe.enabled_features` contains [flagName];
/// - FEATURE_DISABLED dispatches [OnboardingRefreshRequested] (ADR-0008 D6);
/// - every fresh `GetMe` resets what earlier FEATURE_DISABLED answers taught.
ServiceFeatureGate buildServiceGate(
  OnboardingBloc onboardingBloc,
  String flagName, {
  void Function(Object error, StackTrace stack)? onUnexpectedError,
}) {
  final gate = ServiceFeatureGate(
    isEnabled: () => onboardingBloc.state.enabledFeatures.contains(flagName),
    onDisabledByServer: () =>
        onboardingBloc.add(const OnboardingRefreshRequested()),
    onUnexpectedError: onUnexpectedError,
  );
  _wireGateReset(onboardingBloc, gate);
  return gate;
}

/// Builds the `messaging` gate (ADR-0027 D6 / F6) wired to [onboardingBloc]:
/// [MessagingFeatureGate.run] (SendMessage, AcceptMessageRequest) needs
/// `messaging` in `GetMe.enabled_features`; [MessagingFeatureGate.runRead]
/// (the other four RPCs) needs only "not globally off", which the server
/// decides. FEATURE_DISABLED dispatches [OnboardingRefreshRequested] and every
/// fresh `GetMe` resets what earlier answers taught, as for the other gates.
MessagingFeatureGate buildMessagingGate(
  OnboardingBloc onboardingBloc, {
  void Function(Object error, StackTrace stack)? onUnexpectedError,
}) {
  final gate = MessagingFeatureGate(
    isMessagingEnabled: () =>
        onboardingBloc.state.enabledFeatures.contains(kFeatureMessaging),
    onDisabledByServer: () =>
        onboardingBloc.add(const OnboardingRefreshRequested()),
    onUnexpectedError: onUnexpectedError,
  );
  _wireGateReset(onboardingBloc, gate);
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
  NotificationsRepository? notificationsRepository,
  MessagingRepository? messagingRepository,
}) async {
  // Ends the shared SessionEpoch and forgets in-flight and queued timeline
  // work (a new user must never be handed the old user's future).
  // End the epoch here directly, so a wipe path can never leave graph and
  // identity writes unguarded; clearSession then drops the timeline's
  // in-flight maps (it ends the epoch again, which is harmless).
  database.sessionEpoch.end();
  timelineRepository.clearSession();
  notificationsRepository?.clearSession();
  messagingRepository?.clearSession();
  await database.clearAll();
}

/// Bridges auth state into the session (W7-35, L-4): OnboardingBloc reacts to
/// sign-in/sign-out but never talks to AuthBloc directly (the two features stay
/// decoupled, see the `flutter-feature` skill).
///
/// - A user going to null or to a different uid (a direct A to B switch counts)
///   dispatches [OnboardingUserSignedOut], ends the session epoch and wipes the
///   cache ([wipeSessionData]), and calls [onSignedOut] (in-memory caches).
/// - A new uid claims the cache ([AppDatabase.claimCacheFor]: owner stamp, wipe
///   when it is another user's or unstamped) and only then dispatches
///   [OnboardingUserAuthenticated], so nothing reads the cache before it is the
///   user's own.
/// - Every cache step is chained after the previous one, so a sign-in never
///   overtakes the sign-out wipe before it. A failed step is reported and the
///   chain goes on; a failed claim falls back to a plain wipe.
///
/// [initialUser] is the user the app started with (already claimed at startup).
/// Returns the subscription to [authStates].
StreamSubscription<AuthState> wireAuthSession({
  required Stream<AuthState> authStates,
  required OnboardingBloc onboardingBloc,
  required AppDatabase database,
  required TimelineRepository timelineRepository,
  required void Function() onSignedOut,
  NotificationsRepository? notificationsRepository,
  MessagingRepository? messagingRepository,
  AppUser? initialUser,
  UnexpectedErrorReporter onUnexpectedError = reportUnexpectedError,
}) {
  var cacheOps = Future<void>.value();
  AppUser? lastUser;

  void chain(Future<void> Function() step) {
    cacheOps = cacheOps.then((_) => step()).catchError((
      Object error,
      StackTrace stack,
    ) {
      onUnexpectedError(error, stack);
    });
  }

  void authenticate(AppUser user) => unawaited(
    cacheOps.then((_) => onboardingBloc.add(OnboardingUserAuthenticated(user))),
  );

  if (initialUser != null) {
    lastUser = initialUser;
    authenticate(initialUser);
  }
  return authStates.listen((state) {
    final user = state.user;
    final previous = lastUser;
    lastUser = user;
    if (previous != null && (user == null || user.uid != previous.uid)) {
      onboardingBloc.add(const OnboardingUserSignedOut());
      // Privacy: CLAUDE.md rule 10. The epoch ends now (late writes of the
      // old session are dropped); the wipe is awaited by the next step.
      final wipe = wipeSessionData(
        database: database,
        timelineRepository: timelineRepository,
        notificationsRepository: notificationsRepository,
        messagingRepository: messagingRepository,
      );
      chain(() => wipe);
      onSignedOut();
    }
    if (user != null && user.uid != previous?.uid) {
      final uid = user.uid;
      chain(() async {
        try {
          await database.claimCacheFor(uid);
        } catch (_) {
          await database.clearAll();
          rethrow;
        }
      });
      if (state.status == AuthStatus.authenticated) authenticate(user);
    }
  });
}
