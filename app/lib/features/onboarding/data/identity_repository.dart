import 'package:drift/drift.dart' show Value;
import 'package:fixnum/fixnum.dart';

import '../../../core/network/api_client.dart';
import '../../../core/storage/app_database.dart';
import '../../../gen/dzeroth/identity/v1/identity.pb.dart' as identity;

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
}) {
  final request = identity.UpdateProfileRequest(idempotencyKey: idempotencyKey);
  if (avatarMediaId != null) request.avatarMediaId = avatarMediaId;
  if (displayName != null) request.displayName = displayName;
  if (bio != null) request.bio = bio;
  if (bannerMediaId != null) request.bannerMediaId = bannerMediaId;
  if (location != null) request.location = location;
  if (website != null) request.website = website;
  if (pinnedPostId != null) request.pinnedPostId = pinnedPostId;
  return request;
}

/// Talks to `IdentityService` and keeps the local profile cache (drift) in
/// sync, so `GetMe`/`GetProfile` are only ever a Firestore read the client
/// couldn't avoid, never a redundant one (CLAUDE.md prime directive).
class IdentityRepository {
  IdentityRepository({
    required ApiClient apiClient,
    required AppDatabase database,
  }) : _apiClient = apiClient,
       _database = database;

  final ApiClient _apiClient;
  final AppDatabase _database;

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
  /// `FEATURE_MEDIA` off the server answers MEDIA_NOT_READY). Privacy is
  /// deliberately not exposed (the server rejects it until private accounts).
  ///
  /// [bannerMediaId], [location], [website] and [pinnedPostId] are the
  /// `profile_extras` fields (ADR-0024): the server refuses **any** of them,
  /// even an empty one, with FEATURE_DISABLED unless `profile_extras` is on
  /// for the caller, so callers gate them on that flag (the Edit profile
  /// cubit, the pin menu) and pass null otherwise. `""` clears one.
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
      );
      final response = await _apiClient.identity.updateProfile(request);
      await _cacheProfile(response.profile, epoch);
      return response.profile;
    });
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
