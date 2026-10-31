/// The one list of "forget the previous account" steps (privacy: CLAUDE.md
/// rule 10).
///
/// Every holder of per-account **in-memory** state registers a step here once
/// ([register]); `AppWidget` calls [run] when the session ends, and that is
/// the same call for a sign-out and for a direct A to B switch (the auth
/// stream goes A to B without an unauthenticated state in between). A holder
/// that is not registered is not reset, so a new cache is added here, not in a
/// second place.
///
/// Inventory of per-account state and how each is handled (keep in step with
/// the PR that introduced this class, W5-50):
///
/// - Registered (in-memory, reset by [run]): `PendingPostsCubit`,
///   `EngagementCubit`, `PollCubit` (+ `PollRepository` voting memory),
///   `BookmarksCubit` (+ repository overlay), `SuggestionsCubit` (+
///   repository), `TrendsCubit`, `LikesRepository`, `HomeTabsRepository`,
///   `ListsRepository`, `GraphRepository` caches, the app badges, the push
///   token and the snackbars.
/// - Drift cache, wiped by `wipeSessionData` / `claimCacheFor` in
///   `wireAuthSession` (runs on sign-out and on a switch; writes in flight are
///   dropped by the shared `SessionEpoch`): `TimelineRepository` (also its
///   in-flight maps, throttles, `RateLimitHold` and, since W5-50, the
///   list-header hand-off), `NotificationsRepository`, `MessagingRepository`
///   (+ tables), identity and graph writes, `EngagementRepository` (writes
///   through the epoch-guarded timeline store, no memory of its own), recent
///   searches (a drift table, removed by `clearAll`, no epoch).
/// - Safe without a reset: drafts (`DraftsRepository`: every query filters by
///   uid, W6-14); `PushOptInCubit` (keyed by uid, reloaded on every auth
///   state); the theme choice and `ServicePausedCubit` (device-wide);
///   `MediaUploader` reservations (keyed by a per-composition intent id, never
///   reused by another account); `IdentityRepository`, `PostsRepository`,
///   `ConnectSearchRepository`, `ModerationRepository`, `MediaRepository`
///   (hold only capability flags such as "the server refused X" and the shared
///   read hold, no account data); `AccountCubit` and every screen-scoped cubit
///   (built per mount: a sign-out or switch makes `OnboardingBloc` emit its
///   initial state, the router redirects away from every signed-in screen, and
///   the screens are rebuilt for the next account); feature gates (reset by
///   every fresh `GetMe`).
class AccountSessionReset {
  final Map<String, void Function()> _steps = {};

  /// Adds the step [name] (a later registration of the same name replaces
  /// it, so a rebuilt owner never runs twice).
  void register(String name, void Function() step) => _steps[name] = step;

  /// Runs every step. One failing step never stops the others: the error is
  /// handed to [onError] (unexpected-error reporter) and the run goes on.
  void run({void Function(Object error, StackTrace stack)? onError}) {
    for (final step in _steps.values.toList()) {
      try {
        step();
      } on Object catch (error, stack) {
        onError?.call(error, stack);
      }
    }
  }

  /// Names of the registered steps (tests).
  Iterable<String> get names => _steps.keys;
}
