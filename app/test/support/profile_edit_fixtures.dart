import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:mocktail/mocktail.dart';

/// One `IdentityRepository.updateProfile` call, every argument as given
/// (null = the field was left out of the request).
class UpdateProfileCall {
  const UpdateProfileCall({
    required this.idempotencyKey,
    this.displayName,
    this.bio,
    this.avatarMediaId,
    this.bannerMediaId,
    this.location,
    this.website,
    this.pinnedPostId,
  });

  final String idempotencyKey;
  final String? displayName;
  final String? bio;
  final String? avatarMediaId;
  final String? bannerMediaId;
  final String? location;
  final String? website;
  final String? pinnedPostId;

  /// Any of the `profile_extras` fields was sent (even an empty one).
  bool get hasExtras =>
      bannerMediaId != null ||
      location != null ||
      website != null ||
      pinnedPostId != null;
}

/// An `IdentityRepository` that records every `updateProfile` call exactly and
/// answers with the profile the server would return: [profile] with the sent
/// fields applied (`""` clears). Queue failures in [failures]; each call
/// consumes one (null = succeed).
class FakeIdentityRepository extends Fake implements IdentityRepository {
  FakeIdentityRepository(this.profile);

  identity.Profile profile;
  final List<UpdateProfileCall> calls = [];
  final List<Object?> failures = [];

  @override
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
  }) async {
    calls.add(
      UpdateProfileCall(
        idempotencyKey: idempotencyKey,
        displayName: displayName,
        bio: bio,
        avatarMediaId: avatarMediaId,
        bannerMediaId: bannerMediaId,
        location: location,
        website: website,
        pinnedPostId: pinnedPostId,
      ),
    );
    if (failures.isNotEmpty) {
      final failure = failures.removeAt(0);
      if (failure != null) throw failure;
    }
    final next = profile.deepCopy();
    if (displayName != null) next.displayName = displayName;
    if (bio != null) next.bio = bio;
    if (avatarMediaId != null) next.avatarThumbUrl = 'https://cdn.example/a';
    if (bannerMediaId != null) {
      next.bannerUrl = bannerMediaId.isEmpty ? '' : 'https://cdn.example/b';
      next.bannerThumbUrl = bannerMediaId.isEmpty
          ? ''
          : 'https://cdn.example/b_t';
    }
    if (location != null) next.location = location;
    if (website != null) next.website = website;
    if (isPrivate != null) next.isPrivate = isPrivate;
    return profile = next;
  }
}

/// The signed-in user's profile for Edit profile tests.
identity.Profile editableProfile({
  String location = '',
  String website = '',
  bool banner = false,
}) => identity.Profile(
  userId: 'me',
  handle: 'kaif',
  displayName: 'Kaif',
  bio: 'hello',
  location: location,
  website: website,
  bannerUrl: banner ? 'https://cdn.example/old.jpg' : '',
  bannerThumbUrl: banner ? 'https://cdn.example/old_t.jpg' : '',
);
