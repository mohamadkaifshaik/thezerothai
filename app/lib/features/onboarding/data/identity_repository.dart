import 'package:drift/drift.dart' show Value;
import 'package:fixnum/fixnum.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/storage/app_database.dart';
import '../../../gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import '../../profile/domain/profile_edit_feature_flag.dart';

/// How long the Settings "Protect your posts" switch stays hidden after the
/// server refused to turn protection on (FEATURE_DISABLED), as for the other
/// degrade patterns (W3-14, W3-18).
const kPrivateAccountsRefusalBackoff = Duration(minutes: 10);

/// Builds an `UpdateProfile` request where **field presence is the signal**
/// (ADR-0024 D1-D3): a null argument leaves the field out (unchanged), a
/// non-null one sets it, and `""` is a real value that clears
/// `banner_media_id`, `location`, `website` or `pinned_post_id`. Every
/// `UpdateProfile` caller goes through this one place, so the pin menu
/// (W3-17) shapes its request exactly like Edit profile.
identity.UpdateProfileRequest buildUpdateProfileRequest({
  required String idempotencyKey,
  String? displayName,
  String? bio,
  String? avatarMediaId,
  String? bannerMediaId,
  String? location,
  String? website,
  String? pinnedPostId,
  bool? isPrivate,
}) {
  final request = identity.UpdateProfileRequest(idempotencyKey: idempotencyKey);
  if (avatarMediaId != null) request.avatarMediaId = avatarMediaId;
  if (displayName != null) request.displayName = displayName;
  if (bio != null) request.bio = bio;
  if (bannerMediaId != null) request.bannerMediaId = bannerMediaId;
  if (location != null) request.location = location;
  if (website != null) request.website = website;
  if (pinnedPostId != null) request.pinnedPostId = pinnedPostId;
  if (isPrivate != null) request.isPrivate = isPrivate;
  return request;
}

/// Talks to `IdentityService` and keeps the local profile cache (drift) in
/// sync, so `GetMe`/`GetProfile` are only ever a Firestore read the client
/// couldn't avoid, never a redundant one (CLAUDE.md prime directive).
class IdentityRepository {
  IdentityRepository({
    required ApiClient apiClient,
    required AppDatabase database,
    DateTime Function()? clock,
  }) : _apiClient = apiClient,
       _database = database,
       _clock = clock ?? DateTime.now;

  final ApiClient _apiClient;
  final AppDatabase _database;
  final DateTime Function() _clock;

  DateTime? _privateAccountsRefusedAt;

  /// The server answered FEATURE_DISABLED (or UNIMPLEMENTED) to turning
  /// protection ON less than [kPrivateAccountsRefusalBackoff] ago: the Settings
  /// switch stays hidden for a protect-off account until then (W3-33b). Turning
  /// it OFF is never refused (ADR-0025, the undo rule), so it never sets this.
  bool get privateAccountsRefused {
    final at = _privateAccountsRefusedAt;
    return at != null &&
        _clock().difference(at) < kPrivateAccountsRefusalBackoff;
  }

  bool _profileExtrasRefused = false;

  /// The server answered FEATURE_DISABLED `profile_extras` to a pin change
  /// (the flag turned off since `GetMe` listed it): the pin menu rows stay
  /// hidden for the rest of the session, until a fresh [getMe] says what the
  /// flag set is now (the server stays authoritative, ADR-0008 D6).
  bool get profileExtrasRefused => _profileExtrasRefused;

  /// The cached copy of the caller's own profile, if any. Renders instantly
  /// while [getMe] refreshes in the background (cache-first).
  Future<CachedProfile?> cachedOwnProfile(String userId) {
    return _database.profileByUserId(userId);
  }

  /// Throws [ProfileRequiredException] (via [guardApiCall]) if the caller has
  /// a Firebase account but hasn't called [createProfile] yet.
  Future<identity.GetMeResponse> getMe() {
    return guardApiCall(() async {
      final epoch = _database.sessionEpoch.value;
      final response = await _apiClient.identity.getMe(identity.GetMeRequest());
      // A fresh flag set decides again, not an earlier refusal.
      _profileExtrasRefused = false;
      await _cacheProfile(response.profile, epoch);
      return response;
    });
  }

  /// Public profile by id or handle (case-insensitive on the server).
  /// Throws [NotFoundException] (via [guardApiCall]) if the target is
  /// missing, not active, or blocked the caller — byte-identical either way
  /// (ADR-0008 D9): never let the UI hint at which one it was.
  Future<identity.Profile> getProfile({String? userId, String? handle}) {
    assert(
      (userId == null) != (handle == null),
      'getProfile takes exactly one of userId or handle',
    );
    return guardApiCall(() async {
      final epoch = _database.sessionEpoch.value;
      final request = userId != null
          ? identity.GetProfileRequest(userId: userId)
          : identity.GetProfileRequest(handle: handle);
      final response = await _apiClient.identity.getProfile(request);
      await _cacheProfile(response.profile, epoch);
      return response.profile;
    });
  }

  Future<identity.CheckHandleAvailabilityResponse> checkHandleAvailability(
    String handle,
  ) {
    return guardApiCall(
      () => _apiClient.identity.checkHandleAvailability(
        identity.CheckHandleAvailabilityRequest(handle: handle),
      ),
    );
  }

  Future<identity.Profile> createProfile({
    required String handle,
    required String displayName,
    required String idempotencyKey,
  }) {
    return guardApiCall(() async {
      final epoch = _database.sessionEpoch.value;
      final response = await _apiClient.identity.createProfile(
        identity.CreateProfileRequest(
          idempotencyKey: idempotencyKey,
          handle: handle,
          displayName: displayName,
        ),
      );
      await _cacheProfile(response.profile, epoch);
      return response.profile;
    });
  }

  /// Partial update of the caller's own profile (P2): only the non-null
  /// fields are sent and changed (see [buildUpdateProfileRequest]).
  /// [avatarMediaId] is a READY avatar media id from MediaService (P4; with
  /// `FEATURE_MEDIA` off the server answers MEDIA_NOT_READY).
  /// [isPrivate] is the privacy switch (W3-26a); callers send it alone, through
  /// [setProtected].
  ///
  /// [bannerMediaId], [location], [website] and [pinnedPostId] are the
  /// `profile_extras` fields (ADR-0024): the server refuses a **set** of any
  /// of them (a non-empty value, whitespace-only included), and a clear next
  /// to a set, with FEATURE_DISABLED unless `profile_extras` is on for the
  /// caller, so callers gate sets on that flag (the Edit profile cubit, the
  /// pin menu) and pass null otherwise. An exact `""` clears one and is
  /// accepted from any caller whatever the flag (Amendment 1 A2), so without
  /// the flag a caller sends clears alone.
  /// [idempotencyKey] must be reused when retrying the same edit. Updates
  /// the local profile cache with the server's copy.
  Future<identity.Profile> updateProfile({
    required String idempotencyKey,
    String? displayName,
    String? bio,
    String? avatarMediaId,
    String? bannerMediaId,
    String? location,
    String? website,
    String? pinnedPostId,
    bool? isPrivate,
  }) {
    return guardApiCall(() async {
      final epoch = _database.sessionEpoch.value;
      final request = buildUpdateProfileRequest(
        idempotencyKey: idempotencyKey,
        displayName: displayName,
        bio: bio,
        avatarMediaId: avatarMediaId,
        bannerMediaId: bannerMediaId,
        location: location,
        website: website,
        pinnedPostId: pinnedPostId,
        isPrivate: isPrivate,
      );
      final response = await _apiClient.identity.updateProfile(request);
      await _cacheProfile(response.profile, epoch);
      return response.profile;
    });
  }

  /// Protects ([protect] true) or unprotects the caller's posts (W3-26a): an
  /// [updateProfile] that sends only `is_private`, 1 call per change. Turning
  /// it on needs `private_accounts`; a FEATURE_DISABLED / UNIMPLEMENTED answer
  /// is remembered ([privateAccountsRefused], 10 minutes) and rethrown. Turning
  /// it off is accepted whatever the flag. [idempotencyKey] must be reused when
  /// retrying the same intent.
  Future<identity.Profile> setProtected({
    required String idempotencyKey,
    required bool protect,
  }) async {
    try {
      return await updateProfile(
        idempotencyKey: idempotencyKey,
        isPrivate: protect,
      );
    } on FeatureDisabledException {
      if (protect) _privateAccountsRefusedAt = _clock();
      rethrow;
    }
  }

  /// Renames the caller (7-day cooldown on the server). Throws
  /// [HandleTakenException] / [LimitReachedException] (`retryAfter` = time
  /// left of the cooldown) via [guardApiCall]. Updates the profile cache.
  Future<identity.Profile> changeHandle({
    required String idempotencyKey,
    required String newHandle,
  }) {
    return guardApiCall(() async {
      final epoch = _database.sessionEpoch.value;
      final response = await _apiClient.identity.changeHandle(
        identity.ChangeHandleRequest(
          idempotencyKey: idempotencyKey,
          newHandle: newHandle,
        ),
      );
      await _cacheProfile(response.profile, epoch);
      return response.profile;
    });
  }

  /// Pins [postId] to the caller's profile, or unpins with `""` (W3-17): an
  /// [updateProfile] that sends only `pinned_post_id` (`""` stays a present
  /// field, so it clears). Only the caller's own visible POST, QUOTE or REPLY
  /// can be pinned. Pinning needs `profile_extras` for the caller; unpinning
  /// (`""`) never does (Amendment 1 A2). A FEATURE_DISABLED answer for it
  /// (a pin, or an unpin on a revision that predates A2) is remembered
  /// ([profileExtrasRefused]) and rethrown.
  /// [idempotencyKey] must be reused when retrying the same intent.
  Future<identity.Profile> updatePinnedPost({
    required String idempotencyKey,
    required String postId,
  }) async {
    try {
      return await updateProfile(
        idempotencyKey: idempotencyKey,
        pinnedPostId: postId,
      );
    } on FeatureDisabledException catch (error) {
      if (error.feature == kFeatureProfileExtras) _profileExtrasRefused = true;
      rethrow;
    }
  }

  /// Converts a cached row back into the generated [identity.Profile] type,
  /// so callers can render cache and network results the same way.
  identity.Profile profileFromCache(CachedProfile cached) {
    return identity.Profile(
      userId: cached.userId,
      handle: cached.handle,
      displayName: cached.displayName,
      bio: cached.bio,
      avatarUrl: cached.avatarUrl,
      avatarThumbUrl: cached.avatarThumbUrl,
      isPrivate: cached.isPrivate,
      verified: cached.verified,
      followersCount: Int64(cached.followersCount),
      followingCount: Int64(cached.followingCount),
      postsCount: Int64(cached.postsCount),
    );
  }

  Future<void> _cacheProfile(identity.Profile profile, int epoch) {
    return _database.upsertProfile(
      ProfileCacheEntriesCompanion.insert(
        userId: profile.userId,
        handle: profile.handle,
        displayName: profile.displayName,
        bio: Value(profile.bio),
        avatarUrl: Value(profile.avatarUrl),
        avatarThumbUrl: Value(profile.avatarThumbUrl),
        isPrivate: Value(profile.isPrivate),
        verified: Value(profile.verified),
        followersCount: Value(profile.followersCount.toInt()),
        followingCount: Value(profile.followingCount.toInt()),
        postsCount: Value(profile.postsCount.toInt()),
        cachedAt: DateTime.now(),
      ),
      epoch: epoch,
    );
  }
}
