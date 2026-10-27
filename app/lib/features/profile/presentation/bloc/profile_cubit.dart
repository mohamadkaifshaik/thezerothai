import 'package:fixnum/fixnum.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../../gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import '../../../graph/data/graph_repository.dart';
import '../../../onboarding/data/identity_repository.dart';
import 'profile_state.dart';

/// Loads `GetProfile(handle)` and, when the graph flag is on and the profile
/// isn't the viewer's own, the viewer's relationship to it plus whether it
/// follows the viewer (ADR-0024 D7: `GetProfileRelationship`, replacing
/// `GetRelationships` here; cached, so a repeat view of the same profile
/// within a few minutes costs 0 network calls).
class ProfileCubit extends Cubit<ProfileState> {
  ProfileCubit({
    required IdentityRepository identityRepository,
    required GraphRepository graphRepository,
    String? handle,
    String? userId,
    required bool graphEnabled,
    required String? ownUserId,
  }) : _identityRepository = identityRepository,
       _graphRepository = graphRepository,
       _handle = handle,
       _userId = userId,
       _graphEnabled = graphEnabled,
       _ownUserId = ownUserId,
       assert(
         (handle == null) != (userId == null),
         'ProfileCubit takes exactly one of handle or userId',
       ),
       super(const ProfileState());

  final IdentityRepository _identityRepository;
  final GraphRepository _graphRepository;
  final String? _handle;
  final String? _userId;

  /// The handle this cubit was opened with (null when opened by id), for
  /// the app bar title until the profile loads.
  String? get requestedHandle => _handle;
  final bool _graphEnabled;
  final String? _ownUserId;

  Future<void> load() async {
    emit(state.copyWith(status: ProfileStatus.loading, error: null));
    try {
      final profile = _userId != null
          ? await _identityRepository.getProfile(userId: _userId)
          : await _identityRepository.getProfile(handle: _handle);
      final isOwnProfile = profile.userId == _ownUserId;

      graph.Relationship? relationship;
      var followedBy = false;
      if (_graphEnabled && !isOwnProfile) {
        try {
          final known = await _graphRepository.profileRelationshipFor(
            profile.userId,
          );
          relationship = known.relationship;
          followedBy = known.followedBy ?? false;
        } on AppException {
          // The relationship is a nice-to-have on the header; a failure
          // there must never block showing the profile itself. Keep what the
          // session already knew (no chip: "follows you" is unknown).
          relationship = _graphRepository.cached(profile.userId);
        }
      }

      emit(
        ProfileState(
          status: ProfileStatus.ready,
          profile: profile,
          relationship: relationship,
          isOwnProfile: isOwnProfile,
          followedBy: followedBy,
          graphEnabled: _graphEnabled,
        ),
      );
    } on NotFoundException {
      emit(const ProfileState(status: ProfileStatus.notFound));
    } on ValidationException {
      // A malformed id/handle in a typed or stale link: same as not found.
      emit(const ProfileState(status: ProfileStatus.notFound));
    } on AppException catch (e) {
      emit(ProfileState(status: ProfileStatus.error, error: e));
    }
  }

  /// One of the viewer's own posts was deleted from this profile's Posts
  /// tab: the header's post count follows without a reload.
  void postDeleted() {
    final profile = state.profile;
    if (profile == null || profile.postsCount <= Int64.ZERO) return;
    final remaining = profile.postsCount - Int64.ONE;
    emit(
      state.copyWith(
        profile: profile.copyWith((p) => p.postsCount = remaining),
      ),
    );
  }

  /// The viewer deleted their pinned post from its Pinned row: the header's
  /// post count drops and the pin is gone at once (the server unpins in a job
  /// after the delete, so the next read agrees).
  void pinnedPostDeleted() {
    final profile = state.profile;
    if (profile == null) return;
    emit(
      state.copyWith(
        profile: profile.copyWith((p) {
          if (p.postsCount > Int64.ZERO) {
            p.postsCount = p.postsCount - Int64.ONE;
          }
          p.pinnedPostId = '';
        }),
      ),
    );
  }

  /// The viewer's own profile was edited (Edit profile, which returns the
  /// server's profile): show it without a `GetProfile` (0 reads). Ignored
  /// unless it is the profile this cubit shows.
  void profileUpdated(identity.Profile updated) {
    if (state.profile?.userId != updated.userId) return;
    emit(state.copyWith(profile: updated));
  }

  /// Reflects a relationship change (e.g. after Block/Unblock/Mute) without
  /// a full reload.
  void relationshipChanged(graph.Relationship relationship) {
    // A block removes both follow edges (ADR-0008 D9); the viewer's own
    // follow and unfollow never change whether they follow back.
    emit(
      state.copyWith(
        relationship: relationship,
        followedBy: relationship.blocking ? false : state.followedBy,
      ),
    );
  }
}
