/// The one list of "forget the previous account" steps (privacy
/// rule).
///
/// Every holder of per-account **in-memory** state registers a step here once
/// ([register]); `AppWidget` calls [run] when the session ends, and that is
/// the same call for a sign-out and for a direct A to B switch (the auth
/// stream goes A to B without an unauthenticated state in between). A holder
/// that is not registered is not reset, so a new cache is added here, not in a
/// second place.
///
/// Inventory of per-account state and how each is handled (keep in step with
/// the PR that introduced this class):
///
/// - Registered (in-memory, reset by [run]): `PostSender` (stops background
///   sends, releases their photos) and `PendingPostsCubit`,
///   `EngagementCubit`, `PollCubit` (+ `PollRepository` voting memory),
///   `BookmarksCubit` (+ repository overlay), `SuggestionsCubit` (+
///   repository), `TrendsCubit`, `LikesRepository`, `HomeTabsRepository`,
///   `ListsRepository`, `GraphRepository` caches, the app badges, the push
///   token and the snackbars; `PlansSession` (the hoisted `/plans` list and
///   "Your plans" cubits of the tablet list–detail: closed and dropped);
///   `ConversationsSession` (the hoisted inbox and Requests
///   `ConversationsCubit`s and the split page's scroll memory: closed and
///   dropped; also dropped when Messages access turns `hidden`).
/// - SubscriptionCubit and its repository memory are reset together when billing
///   is configured; the SDK operation queue survives account switches.
/// - Drift cache, wiped by `wipeSessionData` / `claimCacheFor` in
///   `wireAuthSession` (runs on sign-out and on a switch; writes in flight are
///   dropped by the shared `SessionEpoch`): `TimelineRepository` (also its
///   in-flight maps, throttles, `RateLimitHold` and, since then, the
///   list-header hand-off), `NotificationsRepository`, `MessagingRepository`
///   (+ tables), identity and graph writes, `EngagementRepository` (writes
///   through the epoch-guarded timeline store, no memory of its own), recent
///   searches (a drift table, removed by `clearAll`, no epoch).
/// - Rate-limit holds of `PostsRepository` and `ConnectSearchRepository`,
///   released by their `clearSession` steps here: a daily search limit would
///   otherwise refuse the next account until midnight without sending a call.
/// - Safe without a reset: drafts (`DraftsRepository`: every query filters by
///   uid); `PushOptInCubit` (keyed by uid, reloaded on every auth
///   state); the theme choice and `ServicePausedCubit` (device-wide);
///   `MediaUploader` reservations (keyed by a per-composition intent id, never
///   reused by another account); `IdentityRepository`,
///   `ModerationRepository`, `MediaRepository` (hold only capability flags
///   such as "the server refused X", no account data); `AccountCubit` and every screen-scoped cubit
///   (built per mount: a sign-out or switch makes `OnboardingBloc` emit its
///   initial state, the router redirects away from every signed-in screen, and
///   the screens are rebuilt for the next account); feature gates (reset by
///   every fresh `GetMe`).
class AccountSessionReset {
  final Map<String, void Function()> _steps = {};
  final Set<String> _idBearing = {};

  /// Adds the step [name] (a later registration of the same name replaces
  /// it, so a rebuilt owner never runs twice). [idBearing] marks a holder of
  /// ids of other users or serialized snapshots of them: [runIdBearing]
  /// (`public_ids` flipped for the signed-in account) runs only those.
  void register(
    String name,
    void Function() step, {
    bool idBearing = false,
  }) {
    _steps[name] = step;
    if (idBearing) {
      _idBearing.add(name);
    } else {
      _idBearing.remove(name);
    }
  }

  /// Runs every step. One failing step never stops the others: the error is
  /// handed to [onError] (unexpected-error reporter) and the run goes on.
  void run({void Function(Object error, StackTrace stack)? onError}) =>
      _run(_steps.keys, onError);

  /// Runs only the steps registered as `idBearing`: the account stays signed
  /// in, so the others (background sends, push, subscriptions, snackbars,
  /// badges) are not touched.
  void runIdBearing({void Function(Object error, StackTrace stack)? onError}) =>
      _run(_idBearing, onError);

  void _run(
    Iterable<String> names,
    void Function(Object error, StackTrace stack)? onError,
  ) {
    for (final name in names.toList()) {
      try {
        _steps[name]?.call();
      } on Object catch (error, stack) {
        onError?.call(error, stack);
      }
    }
  }

  /// Names of the registered steps (tests).
  Iterable<String> get names => _steps.keys;
}
