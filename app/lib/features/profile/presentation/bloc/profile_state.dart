import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../../gen/dzeroth/identity/v1/identity.pb.dart' as identity;

part 'profile_state.freezed.dart';

enum ProfileStatus { loading, ready, notFound, error }

/// State for one `/profile/:handle` view.
@freezed
abstract class ProfileState with _$ProfileState {
  const factory ProfileState({
    @Default(ProfileStatus.loading) ProfileStatus status,
    identity.Profile? profile,
    // Null when the viewer's own profile, or the graph flag is off, or the
    // relationship fetch failed (a nice-to-have on the header — never blocks
    // showing the profile itself).
    graph.Relationship? relationship,
    @Default(false) bool isOwnProfile,
    @Default(false) bool graphEnabled,
    AppException? error,
  }) = _ProfileState;
}
