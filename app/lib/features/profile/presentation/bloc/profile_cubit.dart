import 'package:fixnum/fixnum.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../graph/data/graph_repository.dart';
import '../../../onboarding/data/identity_repository.dart';
import 'profile_state.dart';

/// Loads `GetProfile(handle)` and, when the graph flag is on and the profile
/// isn't the viewer's own, the viewer's relationship to it (ADR-0008 D4:
/// `GetRelationships`, cached, so a repeat view of the same profile this
/// session costs 0 network calls).
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

      var relationship = _graphRepository.cached(profile.userId);
      if (_graphEnabled && !isOwnProfile && relationship == null) {
        try {
          relationship = await _graphRepository.relationshipFor(profile.userId);
        } on AppException {
          // The relationship is a nice-to-have on the header; a failure
          // there must never block showing the profile itself.
          relationship = null;
        }
      } else if (isOwnProfile) {
        relationship = null;
      }

      emit(
        ProfileState(
          status: ProfileStatus.ready,
          profile: profile,
          relationship: relationship,
          isOwnProfile: isOwnProfile,
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

  /// Reflects a relationship change (e.g. after Block/Unblock/Mute) without
  /// a full reload.
  void relationshipChanged(graph.Relationship relationship) {
    emit(state.copyWith(relationship: relationship));
  }
}
